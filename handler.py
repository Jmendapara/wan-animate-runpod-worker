import runpod
from runpod.serverless.utils import rp_upload
import json
import urllib.parse
import time
import os
import requests
import base64
import websocket
import uuid
import tempfile
import socket
import traceback
import logging

from network_volume import (
    is_network_volume_debug_enabled,
    run_network_volume_diagnostics,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

COMFY_API_AVAILABLE_INTERVAL_MS = 50
COMFY_API_AVAILABLE_MAX_RETRIES = 500

WEBSOCKET_RECONNECT_ATTEMPTS = int(os.environ.get("WEBSOCKET_RECONNECT_ATTEMPTS", 5))
WEBSOCKET_RECONNECT_DELAY_S = int(os.environ.get("WEBSOCKET_RECONNECT_DELAY_S", 3))

if os.environ.get("WEBSOCKET_TRACE", "false").lower() == "true":
    websocket.enableTrace(True)

COMFY_HOST = "127.0.0.1:8188"
REFRESH_WORKER = os.environ.get("REFRESH_WORKER", "false").lower() == "true"

# ComfyUI's default input directory — LoadImage and VHS_LoadVideo look here.
COMFY_INPUT_DIR = "/comfyui/input"


# ---------------------------------------------------------------------------
# Reachability / diagnostics helpers (copied verbatim from ltx-video-runpod-worker)
# ---------------------------------------------------------------------------


def _comfy_server_status():
    """Return a dictionary with basic reachability info for the ComfyUI HTTP server."""
    try:
        resp = requests.get(f"http://{COMFY_HOST}/", timeout=5)
        return {
            "reachable": resp.status_code == 200,
            "status_code": resp.status_code,
        }
    except Exception as exc:
        return {"reachable": False, "error": str(exc)}


def _collect_crash_diagnostics():
    """Collect OOM / CUDA / process diagnostics when ComfyUI crashes mid-job."""
    import subprocess

    diag = {}

    try:
        result = subprocess.run(
            ["pgrep", "-f", "comfyui/main.py"],
            capture_output=True, text=True, timeout=5,
        )
        diag["comfyui_process_alive"] = result.returncode == 0
        if result.stdout.strip():
            diag["comfyui_pids"] = result.stdout.strip().split("\n")
    except Exception as e:
        diag["comfyui_process_check_error"] = str(e)

    try:
        result = subprocess.run(
            ["dmesg", "-T"],
            capture_output=True, text=True, timeout=5,
        )
        oom_lines = [
            line for line in result.stdout.splitlines()
            if "oom" in line.lower() or "killed process" in line.lower()
                or "out of memory" in line.lower()
        ]
        if oom_lines:
            diag["oom_kill_detected"] = True
            diag["oom_messages"] = oom_lines[-5:]
        else:
            diag["oom_kill_detected"] = False
    except Exception as e:
        diag["dmesg_error"] = str(e)

    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total,gpu_name",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            diag["gpu_info"] = result.stdout.strip()
        elif result.stderr.strip():
            diag["nvidia_smi_error"] = result.stderr.strip()
    except Exception as e:
        diag["nvidia_smi_error"] = str(e)

    try:
        result = subprocess.run(
            ["free", "-h"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            diag["system_memory"] = result.stdout.strip()
    except Exception as e:
        diag["free_error"] = str(e)

    comfy_log = "/var/log/comfyui.log"
    try:
        if os.path.exists(comfy_log):
            result = subprocess.run(
                ["tail", "-n", "50", comfy_log],
                capture_output=True, text=True, timeout=5,
            )
            if result.stdout.strip():
                diag["comfyui_log_tail"] = result.stdout.strip()
    except Exception as e:
        diag["comfyui_log_error"] = str(e)

    return diag


def _attempt_websocket_reconnect(ws_url, max_attempts, delay_s, initial_error):
    print(
        f"worker-comfyui - Websocket connection closed unexpectedly: {initial_error}. Attempting to reconnect..."
    )
    last_reconnect_error = initial_error
    for attempt in range(max_attempts):
        srv_status = _comfy_server_status()
        if not srv_status["reachable"]:
            print(
                f"worker-comfyui - ComfyUI HTTP unreachable – aborting websocket reconnect: {srv_status.get('error', 'status '+str(srv_status.get('status_code')))}"
            )

            diag = _collect_crash_diagnostics()
            for key, val in diag.items():
                print(f"worker-comfyui - CRASH DIAG [{key}]: {val}")

            crash_reason = "ComfyUI process crashed during execution"
            if diag.get("oom_kill_detected"):
                crash_reason = (
                    "ComfyUI was OOM-killed (out of memory). "
                    "Try a GPU with more VRAM or use a smaller/more quantized model."
                )
            elif diag.get("comfyui_process_alive") is False:
                crash_reason = (
                    "ComfyUI process is no longer running (likely crashed). "
                    "Check logs above for CUDA errors or segfaults."
                )

            raise websocket.WebSocketConnectionClosedException(crash_reason)

        print(
            f"worker-comfyui - Reconnect attempt {attempt + 1}/{max_attempts}... (ComfyUI HTTP reachable, status {srv_status.get('status_code')})"
        )
        try:
            new_ws = websocket.WebSocket()
            new_ws.connect(ws_url, timeout=10)
            print(f"worker-comfyui - Websocket reconnected successfully.")
            return new_ws
        except (
            websocket.WebSocketException,
            ConnectionRefusedError,
            socket.timeout,
            OSError,
        ) as reconn_err:
            last_reconnect_error = reconn_err
            print(
                f"worker-comfyui - Reconnect attempt {attempt + 1} failed: {reconn_err}"
            )
            if attempt < max_attempts - 1:
                print(
                    f"worker-comfyui - Waiting {delay_s} seconds before next attempt..."
                )
                time.sleep(delay_s)
            else:
                print(f"worker-comfyui - Max reconnection attempts reached.")

    print("worker-comfyui - Failed to reconnect websocket after connection closed.")
    raise websocket.WebSocketConnectionClosedException(
        f"Connection closed and failed to reconnect. Last error: {last_reconnect_error}"
    )


# ---------------------------------------------------------------------------
# Input validation (Wan Animate flavor — workflow + r2_inputs)
# ---------------------------------------------------------------------------


def validate_input(job_input):
    """
    Validate the Wan Animate job input.

    Expected shape:
        {
            "workflow": { /* ComfyUI workflow JSON */ },
            "r2_inputs": [
                { "node_id": "57", "input_field": "image", "r2_key": "refs/character.png" },
                { "node_id": "63", "input_field": "video", "r2_key": "drives/dance.mp4" }
            ],
            "comfy_org_api_key": "optional"
        }
    """
    if job_input is None:
        return None, "Please provide input"

    if isinstance(job_input, str):
        try:
            job_input = json.loads(job_input)
        except json.JSONDecodeError:
            return None, "Invalid JSON format in input"

    workflow = job_input.get("workflow")
    if workflow is None:
        return None, "Missing 'workflow' parameter"

    r2_inputs = job_input.get("r2_inputs")
    if r2_inputs is not None:
        if not isinstance(r2_inputs, list):
            return None, "'r2_inputs' must be a list"
        for i, entry in enumerate(r2_inputs):
            if not isinstance(entry, dict):
                return None, f"r2_inputs[{i}] must be an object"
            for req in ("node_id", "input_field", "r2_key"):
                if req not in entry:
                    return (
                        None,
                        f"r2_inputs[{i}] is missing required field '{req}'",
                    )

    comfy_org_api_key = job_input.get("comfy_org_api_key")

    return {
        "workflow": workflow,
        "r2_inputs": r2_inputs or [],
        "comfy_org_api_key": comfy_org_api_key,
    }, None


# ---------------------------------------------------------------------------
# R2 input download
# ---------------------------------------------------------------------------


def _make_s3_client():
    """Create a boto3 S3 client pointing at the configured R2 endpoint."""
    import boto3

    endpoint = os.environ.get("BUCKET_ENDPOINT_URL")
    access_key = os.environ.get("BUCKET_ACCESS_KEY_ID")
    secret_key = os.environ.get("BUCKET_SECRET_ACCESS_KEY")
    if not endpoint or not access_key or not secret_key:
        raise ValueError(
            "R2 credentials not configured. BUCKET_ENDPOINT_URL, BUCKET_ACCESS_KEY_ID, "
            "and BUCKET_SECRET_ACCESS_KEY must all be set to fetch inputs from R2."
        )
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )


def process_r2_inputs(workflow, r2_inputs):
    """
    Download each R2 input into /comfyui/input/<basename> and rewrite the
    corresponding field in the workflow to reference the local filename.

    ComfyUI's LoadImage / VHS_LoadVideo (and any file-loading node) resolves
    relative filenames against /comfyui/input by default.
    """
    if not r2_inputs:
        return

    os.makedirs(COMFY_INPUT_DIR, exist_ok=True)

    input_bucket = os.environ.get("R2_INPUT_BUCKET_NAME") or os.environ.get(
        "R2_BUCKET_NAME"
    )
    if not input_bucket:
        raise ValueError(
            "No input bucket configured. Set R2_INPUT_BUCKET_NAME or R2_BUCKET_NAME."
        )

    s3 = _make_s3_client()

    print(
        f"worker-comfyui - Downloading {len(r2_inputs)} R2 input(s) from bucket '{input_bucket}'..."
    )
    for entry in r2_inputs:
        node_id = str(entry["node_id"])
        field = entry["input_field"]
        key = entry["r2_key"]

        if node_id not in workflow:
            raise ValueError(
                f"r2_inputs references node_id '{node_id}' which is not in the workflow"
            )
        if "inputs" not in workflow[node_id]:
            raise ValueError(
                f"Workflow node '{node_id}' has no 'inputs' dict to populate"
            )

        filename = os.path.basename(key)
        local_path = os.path.join(COMFY_INPUT_DIR, filename)

        print(
            f"worker-comfyui - R2: {key} -> {local_path} (node {node_id}.{field})"
        )
        s3.download_file(input_bucket, key, local_path)

        workflow[node_id]["inputs"][field] = filename

    print(f"worker-comfyui - R2 inputs ready.")


# ---------------------------------------------------------------------------
# ComfyUI interaction helpers (copied verbatim from ltx-video-runpod-worker)
# ---------------------------------------------------------------------------


def check_server(url, retries=500, delay=50):
    print(f"worker-comfyui - Checking API server at {url}...")
    for i in range(retries):
        try:
            response = requests.get(url, timeout=5)
            if response.status_code == 200:
                print(f"worker-comfyui - API is reachable")
                return True
        except requests.Timeout:
            pass
        except requests.RequestException:
            pass
        time.sleep(delay / 1000)

    print(
        f"worker-comfyui - Failed to connect to server at {url} after {retries} attempts."
    )
    return False


def get_available_models():
    try:
        response = requests.get(f"http://{COMFY_HOST}/object_info", timeout=10)
        response.raise_for_status()
        object_info = response.json()

        available_models = {}
        if "CheckpointLoaderSimple" in object_info:
            checkpoint_info = object_info["CheckpointLoaderSimple"]
            if "input" in checkpoint_info and "required" in checkpoint_info["input"]:
                ckpt_options = checkpoint_info["input"]["required"].get("ckpt_name")
                if ckpt_options and len(ckpt_options) > 0:
                    available_models["checkpoints"] = (
                        ckpt_options[0] if isinstance(ckpt_options[0], list) else []
                    )

        return available_models
    except Exception as e:
        print(f"worker-comfyui - Warning: Could not fetch available models: {e}")
        return {}


def queue_workflow(workflow, client_id, comfy_org_api_key=None):
    payload = {"prompt": workflow, "client_id": client_id}

    key_from_env = os.environ.get("COMFY_ORG_API_KEY")
    effective_key = comfy_org_api_key if comfy_org_api_key else key_from_env
    if effective_key:
        payload["extra_data"] = {"api_key_comfy_org": effective_key}
    data = json.dumps(payload).encode("utf-8")

    headers = {"Content-Type": "application/json"}
    response = requests.post(
        f"http://{COMFY_HOST}/prompt", data=data, headers=headers, timeout=30
    )

    if response.status_code == 400:
        print(f"worker-comfyui - ComfyUI returned 400. Response body: {response.text}")
        try:
            error_data = response.json()
            error_message = "Workflow validation failed"
            error_details = []

            if "error" in error_data:
                error_info = error_data["error"]
                if isinstance(error_info, dict):
                    error_message = error_info.get("message", error_message)
                else:
                    error_message = str(error_info)

            if "node_errors" in error_data:
                for node_id, node_error in error_data["node_errors"].items():
                    if isinstance(node_error, dict):
                        for error_type, error_msg in node_error.items():
                            error_details.append(
                                f"Node {node_id} ({error_type}): {error_msg}"
                            )
                    else:
                        error_details.append(f"Node {node_id}: {node_error}")

            if error_details:
                detailed_message = f"{error_message}:\n" + "\n".join(
                    f"• {detail}" for detail in error_details
                )
                raise ValueError(detailed_message)
            raise ValueError(f"{error_message}. Raw response: {response.text}")
        except (json.JSONDecodeError, KeyError):
            raise ValueError(
                f"ComfyUI validation failed (could not parse error response): {response.text}"
            )

    response.raise_for_status()
    return response.json()


def get_history(prompt_id):
    response = requests.get(f"http://{COMFY_HOST}/history/{prompt_id}", timeout=30)
    response.raise_for_status()
    return response.json()


def get_file_data(filename, subfolder, file_type):
    print(
        f"worker-comfyui - Fetching file data: type={file_type}, subfolder={subfolder}, filename={filename}"
    )
    data = {"filename": filename, "subfolder": subfolder, "type": file_type}
    url_values = urllib.parse.urlencode(data)
    try:
        response = requests.get(f"http://{COMFY_HOST}/view?{url_values}", timeout=120)
        response.raise_for_status()
        print(f"worker-comfyui - Successfully fetched file data for {filename}")
        return response.content
    except requests.Timeout:
        print(f"worker-comfyui - Timeout fetching file data for {filename}")
        return None
    except requests.RequestException as e:
        print(f"worker-comfyui - Error fetching file data for {filename}: {e}")
        return None
    except Exception as e:
        print(
            f"worker-comfyui - Unexpected error fetching file data for {filename}: {e}"
        )
        return None


# ---------------------------------------------------------------------------
# Output filtering — VHS_VideoCombine writes three files per run (silent .mp4,
# .png thumbnail, -audio.mp4). We only surface the audio-bearing one.
# ---------------------------------------------------------------------------


def _is_wanted_output(media_key, filename):
    # VHS_VideoCombine reports the MP4 under the legacy `gifs` key — check the
    # filename regardless of which category ComfyUI filed it under.
    if not filename:
        return False
    return filename.endswith("-audio.mp4")


# ---------------------------------------------------------------------------
# Main handler
# ---------------------------------------------------------------------------


def handler(job):
    if is_network_volume_debug_enabled():
        run_network_volume_diagnostics()

    job_input = job["input"]
    job_id = job["id"]

    validated_data, error_message = validate_input(job_input)
    if error_message:
        return {"error": error_message}

    workflow = validated_data["workflow"]
    r2_inputs = validated_data["r2_inputs"]

    if not check_server(
        f"http://{COMFY_HOST}/",
        COMFY_API_AVAILABLE_MAX_RETRIES,
        COMFY_API_AVAILABLE_INTERVAL_MS,
    ):
        return {
            "error": f"ComfyUI server ({COMFY_HOST}) not reachable after multiple retries."
        }

    # Download R2 inputs and rewrite the workflow to point at local filenames.
    try:
        process_r2_inputs(workflow, r2_inputs)
    except Exception as e:
        print(f"worker-comfyui - R2 input download failed: {e}")
        print(traceback.format_exc())
        return {"error": f"Failed to download R2 inputs: {e}"}

    ws = None
    client_id = str(uuid.uuid4())
    prompt_id = None
    output_videos = []
    errors = []

    try:
        ws_url = f"ws://{COMFY_HOST}/ws?clientId={client_id}"
        print(f"worker-comfyui - Connecting to websocket: {ws_url}")
        ws = websocket.WebSocket()
        ws.connect(ws_url, timeout=10)
        print(f"worker-comfyui - Websocket connected")

        try:
            queued_workflow = queue_workflow(
                workflow,
                client_id,
                comfy_org_api_key=validated_data.get("comfy_org_api_key"),
            )
            prompt_id = queued_workflow.get("prompt_id")
            if not prompt_id:
                raise ValueError(
                    f"Missing 'prompt_id' in queue response: {queued_workflow}"
                )
            print(f"worker-comfyui - Queued workflow with ID: {prompt_id}")
        except requests.RequestException as e:
            print(f"worker-comfyui - Error queuing workflow: {e}")
            raise ValueError(f"Error queuing workflow: {e}")
        except Exception as e:
            print(f"worker-comfyui - Unexpected error queuing workflow: {e}")
            if isinstance(e, ValueError):
                raise e
            raise ValueError(f"Unexpected error queuing workflow: {e}")

        print(f"worker-comfyui - Waiting for workflow execution ({prompt_id})...")
        execution_done = False
        while True:
            try:
                out = ws.recv()
                if isinstance(out, str):
                    message = json.loads(out)
                    if message.get("type") == "status":
                        status_data = message.get("data", {}).get("status", {})
                        print(
                            f"worker-comfyui - Status update: {status_data.get('exec_info', {}).get('queue_remaining', 'N/A')} items remaining in queue"
                        )
                    elif message.get("type") == "executing":
                        data = message.get("data", {})
                        if (
                            data.get("node") is None
                            and data.get("prompt_id") == prompt_id
                        ):
                            print(
                                f"worker-comfyui - Execution finished for prompt {prompt_id}"
                            )
                            execution_done = True
                            break
                    elif message.get("type") == "execution_error":
                        data = message.get("data", {})
                        if data.get("prompt_id") == prompt_id:
                            error_details = f"Node Type: {data.get('node_type')}, Node ID: {data.get('node_id')}, Message: {data.get('exception_message')}"
                            print(
                                f"worker-comfyui - Execution error received: {error_details}"
                            )
                            errors.append(f"Workflow execution error: {error_details}")
                            break
                else:
                    continue
            except websocket.WebSocketTimeoutException:
                print(f"worker-comfyui - Websocket receive timed out. Still waiting...")
                continue
            except websocket.WebSocketConnectionClosedException as closed_err:
                try:
                    ws = _attempt_websocket_reconnect(
                        ws_url,
                        WEBSOCKET_RECONNECT_ATTEMPTS,
                        WEBSOCKET_RECONNECT_DELAY_S,
                        closed_err,
                    )
                    print(
                        "worker-comfyui - Resuming message listening after successful reconnect."
                    )
                    continue
                except websocket.WebSocketConnectionClosedException as reconn_failed_err:
                    raise reconn_failed_err
            except json.JSONDecodeError:
                print(f"worker-comfyui - Received invalid JSON message via websocket.")

        if not execution_done and not errors:
            raise ValueError(
                "Workflow monitoring loop exited without confirmation of completion or error."
            )

        print(f"worker-comfyui - Fetching history for prompt {prompt_id}...")
        history = get_history(prompt_id)

        if prompt_id not in history:
            error_msg = f"Prompt ID {prompt_id} not found in history after execution."
            print(f"worker-comfyui - {error_msg}")
            if not errors:
                return {"error": error_msg}
            errors.append(error_msg)
            return {
                "error": "Job processing failed, prompt ID not found in history.",
                "details": errors,
            }

        prompt_history = history.get(prompt_id, {})
        outputs = prompt_history.get("outputs", {})

        if not outputs:
            warning_msg = f"No outputs found in history for prompt {prompt_id}."
            print(f"worker-comfyui - {warning_msg}")
            if not errors:
                errors.append(warning_msg)

        print(f"worker-comfyui - Processing {len(outputs)} output nodes...")
        for node_id, node_output in outputs.items():
            for media_key in ("images", "videos", "gifs"):
                if media_key not in node_output:
                    continue

                items = node_output[media_key]
                print(
                    f"worker-comfyui - Node {node_id} produced {len(items)} {media_key}"
                )
                for item_info in items:
                    filename = item_info.get("filename")
                    subfolder = item_info.get("subfolder", "")
                    item_type = item_info.get("type")

                    if item_type == "temp":
                        print(
                            f"worker-comfyui - Skipping {media_key} {filename} because type is 'temp'"
                        )
                        continue

                    # Filter out VHS sidecars (silent .mp4, .png thumbnail).
                    # Only the -audio.mp4 from node 186 is the deliverable.
                    if not _is_wanted_output(media_key, filename):
                        print(
                            f"worker-comfyui - Skipping sidecar {media_key} {filename}"
                        )
                        continue

                    if not filename:
                        continue

                    file_bytes = get_file_data(filename, subfolder, item_type)
                    if not file_bytes:
                        error_msg = f"Failed to fetch {media_key} data for {filename} from /view endpoint."
                        errors.append(error_msg)
                        continue

                    file_extension = os.path.splitext(filename)[1] or ".mp4"

                    if os.environ.get("BUCKET_ENDPOINT_URL"):
                        temp_file_path = None
                        try:
                            with tempfile.NamedTemporaryFile(
                                suffix=file_extension, delete=False
                            ) as temp_file:
                                temp_file.write(file_bytes)
                                temp_file_path = temp_file.name
                            print(
                                f"worker-comfyui - Wrote {filename} to temporary file: {temp_file_path}"
                            )
                            print(f"worker-comfyui - Uploading {filename} to S3...")
                            s3_url = rp_upload.upload_image(
                                job_id,
                                temp_file_path,
                                bucket_name=os.environ.get("R2_BUCKET_NAME"),
                            )
                            print(
                                f"worker-comfyui - Uploaded {filename} to S3: {s3_url}"
                            )
                            output_videos.append(
                                {
                                    "filename": filename,
                                    "type": "s3_url",
                                    "data": s3_url,
                                }
                            )
                        except Exception as e:
                            error_msg = f"Error uploading {filename} to S3: {e}"
                            print(f"worker-comfyui - {error_msg}")
                            errors.append(error_msg)
                        finally:
                            if temp_file_path and os.path.exists(temp_file_path):
                                try:
                                    os.remove(temp_file_path)
                                except OSError as rm_err:
                                    print(
                                        f"worker-comfyui - Error removing temp file {temp_file_path}: {rm_err}"
                                    )
                    else:
                        try:
                            file_size_mb = len(file_bytes) / (1024 * 1024)
                            if file_size_mb > 15:
                                print(
                                    f"worker-comfyui - WARNING: {filename} is {file_size_mb:.1f} MB. "
                                    f"Large video responses may be truncated by RunPod. "
                                    f"Configure S3 upload (BUCKET_ENDPOINT_URL) for reliable delivery."
                                )
                            base64_data = base64.b64encode(file_bytes).decode("utf-8")
                            output_videos.append(
                                {
                                    "filename": filename,
                                    "type": "base64",
                                    "data": base64_data,
                                }
                            )
                            print(
                                f"worker-comfyui - Encoded {filename} as base64 ({file_size_mb:.1f} MB)"
                            )
                        except Exception as e:
                            error_msg = f"Error encoding {filename} to base64: {e}"
                            print(f"worker-comfyui - {error_msg}")
                            errors.append(error_msg)

    except websocket.WebSocketException as e:
        print(f"worker-comfyui - WebSocket Error: {e}")
        print(traceback.format_exc())
        return {"error": f"ComfyUI communication lost: {e}"}
    except requests.RequestException as e:
        print(f"worker-comfyui - HTTP Request Error: {e}")
        print(traceback.format_exc())
        return {"error": f"HTTP communication error with ComfyUI: {e}"}
    except ValueError as e:
        print(f"worker-comfyui - Value Error: {e}")
        print(traceback.format_exc())
        return {"error": str(e)}
    except Exception as e:
        print(f"worker-comfyui - Unexpected Handler Error: {e}")
        print(traceback.format_exc())
        return {"error": f"An unexpected error occurred: {e}"}
    finally:
        if ws and ws.connected:
            print(f"worker-comfyui - Closing websocket connection.")
            ws.close()

    final_result = {}
    if output_videos:
        final_result["videos"] = output_videos

    if errors:
        final_result["errors"] = errors
        print(f"worker-comfyui - Job completed with errors/warnings: {errors}")

    if not output_videos and errors:
        print(f"worker-comfyui - Job failed with no output.")
        return {
            "error": "Job processing failed",
            "details": errors,
        }
    if not output_videos and not errors:
        print(
            f"worker-comfyui - Job completed successfully, but the workflow produced no -audio.mp4 output."
        )
        final_result["status"] = "success_no_output"
        final_result["videos"] = []

    print(
        f"worker-comfyui - Job completed. Returning {len(output_videos)} video(s)."
    )
    return final_result


if __name__ == "__main__":
    print("worker-comfyui - Starting handler...")
    runpod.serverless.start({"handler": handler})
