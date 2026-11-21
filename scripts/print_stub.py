#!/usr/bin/env python3
"""Local stand-in for the print endpoint, for development and UI tests.

Mirrors the live contract: POST /print takes multipart form data with either
`mesh` (an .obj, .ply or .usdz file in metres) or `photo` (.jpg/.png) plus an
optional `height_mm`, or `mode=face` with a front-camera `photo`, `intrinsics`,
`camera_transform`, `image_orientation`, optional `depth` (float32 metres) with
`depth_width`/`depth_height`/`depth_intrinsics`/`depth_extrinsics`, `face_transform`,
`face_vertices` (float32 xyz) with `face_vertex_count` and `height_mm`; turn-your-head scans add
`view_count` and, per extra view i >= 1, `view_<i>_photo`, `view_<i>_image_orientation`,
`view_<i>_intrinsics`, `view_<i>_camera_transform`, `view_<i>_face_transform`, `view_<i>_yaw_deg`
and optional `view_<i>_depth` with `view_<i>_depth_width`/`_height`/`_intrinsics`/`_extrinsics`. Photo + depth
fusion adds `depth` (float32 metres), `depth_width`, `depth_height`, `intrinsics`,
`image_orientation` and optional `depth_confidence`, `object_points`; any photo may
carry `camera_transform` with `image_orientation`.
Every print takes a client UUID `job_id`. NDJSON clients get accepted,
progress and terminal events; GET /print/{id} replays progress, and
GET /print/{id}/result long-polls an STL. Legacy clients get `model/stl` and an
`X-Print-Report` JSON header. Errors are JSON `{"detail": ...}`. With --token,
requests must carry `Authorization: Bearer <token>` or get a 401. GET /last returns a JSON summary
of the last accepted print request, for UI tests.

Signed uploads: POST /print/uploads takes JSON {"job_id", "files": {name: {"content_type", "size"}}}
(names: mesh, photo, depth, depth_confidence, face_vertices, view_<i>_photo, view_<i>_depth) and returns {"job_id", "expires_in": 900,
"uploads": {name: {"url", "method": "PUT", "headers", "file_id", "get_url"}}}; a repeated request returns fresh URLs for the same
job. PUT /s3/<job>/<name> needs exactly those headers, no Authorization, a live signature and the declared
size, else 403 (expired or bad signature, S3-style XML) or 400. GET /print/uploads/<job> confirms
all planned files exist and refreshes their signed GET URLs. Completion includes a signed `stl_url` for
the stored STL. /compat uses the older signed-upload response and inline STL. POST /print with `job_id` and
`uploaded=<names>` (form fields, no file parts) uses the stored files, or answers 409
{"detail": "upload missing: depth", "missing": ["depth"]}. Test modes go in front of the base path,
joined by "-": /fail (job errors at repair), /expire (each job's first URL per file is already expired),
/drop (the first submit of each job reports its first file missing), /legacy (no /print/uploads: 405),
/deny (every PUT is refused 403 AccessDenied, like a bucket without an IAM policy).

POST /photo-check takes `photo` plus optional `camera_transform` and answers
`{ok, issues: [{code, message}], camera_pitch_deg, angle_checked, max_pitch_deg}`; like the
live check it flags `steep_angle` when the camera looks more than 30 degrees below level.

    python3 scripts/print_stub.py            # listens on 0.0.0.0:8765
    python3 scripts/print_stub.py --port 9000 --delay 2 --token secret
"""
import argparse
import base64
import email.parser
import email.policy
import json
import math
import re
import time
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MESH_EXTENSIONS = (".obj", ".ply", ".usdz")
PHOTO_EXTENSIONS = (".jpg", ".jpeg", ".png")
MAX_UPLOAD_BYTES = 200 * 1024 * 1024
UPLOAD_NAMES = ("mesh", "photo", "depth", "depth_confidence", "face_vertices")
UPLOAD_FILENAMES = {"photo": "photo.jpg", "depth": "depth.f32", "depth_confidence": "confidence.u8",
                    "face_vertices": "face_vertices.f32"}
VIEW_UPLOAD = re.compile(r"^view_([1-9][0-9]*)_(photo|depth)$")
MAX_FACE_VIEWS = 5


def is_upload_name(name):
    return name in UPLOAD_NAMES or bool(VIEW_UPLOAD.match(name))


def upload_filename(name):
    view = VIEW_UPLOAD.match(name)
    if view:
        return "view_%s_%s" % (view.group(1), "face.jpg" if view.group(2) == "photo" else "depth.f32")
    return UPLOAD_FILENAMES[name]


MESH_TYPES = {"model/vnd.usdz+zip": ".usdz", "model/obj": ".obj", "application/x-ply": ".ply"}
MODES = ("fail", "expire", "drop", "legacy", "deny")
UPLOAD_EXPIRES = 900


def split_mode(path):
    """('/expire-drop/print', ...) -> ({'expire', 'drop'}, '/print')."""
    parts = path.split("?")[0].rstrip("/").split("/")
    if len(parts) > 1 and parts[1] and all(mode in (*MODES, "compat") for mode in parts[1].split("-")):
        return set(parts[1].split("-")), "/" + "/".join(parts[2:])
    return set(), path.split("?")[0].rstrip("/")


class Uploads:
    """One job's signed URLs, stored files and counters."""
    def __init__(self):
        self.slots = {}
        self.files = {}
        self.stats = {"url_requests": 0, "puts": 0, "rejected_puts": 0, "conflicts": 0}
        self.dropped = False
        self.denied = False


class Job:
    def __init__(self, job_id, stem, delay, fail_stage, inline_stl):
        self.id = job_id
        self.stem = stem
        self.condition = threading.Condition()
        self.events = []
        self.terminal = None
        self.inline_stl = inline_stl
        self.stl = None
        self.download_slot = {}
        self.report = {"extents_mm": [20.0, 20.0, 20.0], "watertight": True, "volume_cm3": 8.0}
        threading.Thread(target=self.run, args=(delay, fail_stage), daemon=True).start()

    def emit(self, event):
        with self.condition:
            self.events.append(event)
            if event["type"] in ("done", "error"):
                self.terminal = event
            self.condition.notify_all()

    def run(self, delay, fail_stage):
        stages = ["upload", "background removal", "TripoSR", "depth fusion", "repair", "export"]
        for index, stage in enumerate(stages):
            event = {"type": "progress", "stage": stage, "message": "Processing: " + stage,
                     "progress": index / len(stages)}
            self.emit(event)
            remaining = max(0, delay) / len(stages)
            while remaining > 0:
                interval = min(2, remaining)
                time.sleep(interval)
                remaining -= interval
                self.emit(event)
            if stage == fail_stage:
                self.emit({"type": "error", "detail": "Stub failed during " + stage})
                return
        self.stl = cube_stl()
        self.emit({"type": "done", "filename": self.stem + ".stl", "report": self.report})


def cube_stl(size_mm=20.0):
    s = size_mm
    v = [(x * s, y * s, z * s) for x in (0, 1) for y in (0, 1) for z in (0, 1)]
    faces = [
        ((-1, 0, 0), (0, 1, 3), (0, 3, 2)), ((1, 0, 0), (4, 6, 7), (4, 7, 5)),
        ((0, -1, 0), (0, 4, 5), (0, 5, 1)), ((0, 1, 0), (2, 3, 7), (2, 7, 6)),
        ((0, 0, -1), (0, 2, 6), (0, 6, 4)), ((0, 0, 1), (1, 5, 7), (1, 7, 3)),
    ]
    lines = ["solid stub_cube"]
    for normal, *tris in faces:
        for tri in tris:
            lines.append("  facet normal %g %g %g" % normal)
            lines.append("    outer loop")
            lines.extend("      vertex %g %g %g" % v[i] for i in tri)
            lines.append("    endloop")
            lines.append("  endfacet")
    lines.append("endsolid stub_cube")
    return ("\n".join(lines) + "\n").encode()


def parse_multipart(content_type, body):
    message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
    )
    if not message.is_multipart():
        return {}
    parts = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            parts[name] = (part.get_filename(), part.get_payload(decode=True) or b"")
    return parts


def check_face(parts):
    """Validates the `mode=face` fields and returns a summary of them."""
    def text(name):
        return parts[name][1].decode() if name in parts else None

    def matrix(name, size=16):
        value = json.loads(text(name)) if name in parts else None
        if value is not None and (not isinstance(value, list) or len(value) != size):
            raise ValueError("%s must be %d numbers" % (name, size))
        return value

    def intrinsics(name):
        value = json.loads(text(name)) if name in parts else None
        if value is not None and not (isinstance(value, dict) and all(k in value for k in ("fx", "fy", "cx", "cy", "width", "height"))):
            raise ValueError("%s must have fx, fy, cx, cy, width and height" % name)
        return value

    try:
        summary = {
            "mode": "face",
            "image_orientation": int(text("image_orientation") or 1),
            "intrinsics": intrinsics("intrinsics"),
            "camera_transform": matrix("camera_transform"),
            "face_transform": matrix("face_transform"),
            "depth_intrinsics": intrinsics("depth_intrinsics"),
            "depth_extrinsics": matrix("depth_extrinsics"),
            "height_mm": float(text("height_mm") or 100),
        }
        if "depth" in parts:
            width, height = int(text("depth_width")), int(text("depth_height"))
            if width <= 0 or height <= 0 or len(parts["depth"][1]) != width * height * 4:
                raise ValueError("depth must be depth_width x depth_height float32 values")
            summary.update(depth_width=width, depth_height=height)
        if "face_vertices" in parts:
            count = int(text("face_vertex_count"))
            if count <= 0 or len(parts["face_vertices"][1]) != count * 12:
                raise ValueError("face_vertices must be face_vertex_count x 3 float32 values")
            summary["face_vertex_count"] = count
        if "view_count" in parts:
            view_count = int(text("view_count"))
            if not 1 <= view_count <= MAX_FACE_VIEWS:
                raise ValueError("view_count must be 1 to %d" % MAX_FACE_VIEWS)
            summary["view_count"] = view_count
            summary["views"] = [check_face_view(parts, i, text, matrix, intrinsics) for i in range(1, view_count)]
    except (TypeError, ValueError) as error:
        raise ValueError(str(error) if str(error).startswith(("depth", "face", "camera", "intrinsics", "view")) else "face fields must be numbers or JSON")
    if summary["image_orientation"] not in (1, 3, 6, 8):
        raise ValueError("image_orientation must be 1, 3, 6 or 8")
    if summary["height_mm"] <= 0:
        raise ValueError("height_mm must be a positive number")
    return summary


def check_face_view(parts, index, text, matrix, intrinsics):
    """Validates one turn-your-head view's `view_<index>_*` fields and returns a summary of it."""
    prefix = "view_%d_" % index
    if not parts.get(prefix + "photo", (None, b""))[1]:
        raise ValueError("view %d needs %sphoto" % (index, prefix))
    for name in ("intrinsics", "camera_transform", "face_transform"):
        if prefix + name not in parts:
            raise ValueError("view %d needs %s%s" % (index, prefix, name))
    view = {
        "image_orientation": int(text(prefix + "image_orientation") or 1),
        "intrinsics": intrinsics(prefix + "intrinsics"),
        "camera_transform": matrix(prefix + "camera_transform"),
        "face_transform": matrix(prefix + "face_transform"),
        "yaw_deg": float(text(prefix + "yaw_deg")) if prefix + "yaw_deg" in parts else None,
    }
    if view["image_orientation"] not in (1, 3, 6, 8):
        raise ValueError("view %d image_orientation must be 1, 3, 6 or 8" % index)
    if prefix + "depth" in parts:
        width, height = int(text(prefix + "depth_width")), int(text(prefix + "depth_height"))
        if width <= 0 or height <= 0 or len(parts[prefix + "depth"][1]) != width * height * 4:
            raise ValueError("view %d depth must be depth_width x depth_height float32 values" % index)
        view.update(depth_width=width, depth_height=height, depth_intrinsics=intrinsics(prefix + "depth_intrinsics"))
    return view


def check_pose(parts):
    """Validates `image_orientation` and the optional `camera_transform`."""
    try:
        orientation = int(parts["image_orientation"][1].decode())
        transform = json.loads(parts["camera_transform"][1].decode()) if "camera_transform" in parts else None
    except (KeyError, TypeError, ValueError):
        raise ValueError("image_orientation and camera_transform must be a number and JSON")
    if orientation not in (1, 3, 6, 8):
        raise ValueError("image_orientation must be 1, 3, 6 or 8")
    if transform is not None and (not isinstance(transform, list) or len(transform) != 16):
        raise ValueError("camera_transform must be 16 numbers")
    return {"image_orientation": orientation, "camera_transform": transform}


def check_depth(parts):
    """Validates the photo + depth fields and returns a summary of them."""
    def field(name, required=True):
        if name not in parts:
            if required:
                raise ValueError("%s is required with depth" % name)
            return None
        return parts[name][1].decode()

    try:
        width, height = int(field("depth_width")), int(field("depth_height"))
        intrinsics = json.loads(field("intrinsics"))
        points = json.loads(field("object_points", False) or "[]")
    except (TypeError, ValueError):
        raise ValueError("depth fields must be numbers or JSON")
    if width <= 0 or height <= 0 or len(parts["depth"][1]) != width * height * 4:
        raise ValueError("depth must be depth_width x depth_height float32 values")
    if "depth_confidence" in parts and len(parts["depth_confidence"][1]) != width * height:
        raise ValueError("depth_confidence must be depth_width x depth_height bytes")
    if not isinstance(intrinsics, dict) or not all(k in intrinsics for k in ("fx", "fy", "cx", "cy", "width", "height")):
        raise ValueError("intrinsics must have fx, fy, cx, cy, width and height")
    return {
        "depth_width": width, "depth_height": height, "intrinsics": intrinsics,
        "object_points": points, "has_confidence": "depth_confidence" in parts,
    }


MAX_PITCH_DEG = 30.0


def photo_check(parts):
    """The live check's angle rule: pitch below level from the camera's forward (-Z) axis."""
    if "camera_transform" not in parts:
        return {"ok": True, "issues": [], "camera_pitch_deg": None, "angle_checked": False, "max_pitch_deg": MAX_PITCH_DEG}
    transform = check_pose(dict(parts, image_orientation=(None, b"1")))["camera_transform"]
    pitch = round(math.degrees(math.asin(max(-1.0, min(1.0, transform[9])))), 1)
    issues = []
    if pitch > MAX_PITCH_DEG:
        issues.append({"code": "steep_angle", "message": "The phone is pointing %g° down. Hold it closer to level with the object (%g° at most)." % (pitch, MAX_PITCH_DEG)})
    return {"ok": not issues, "issues": issues, "camera_pitch_deg": pitch, "angle_checked": True, "max_pitch_deg": MAX_PITCH_DEG}


class Handler(BaseHTTPRequestHandler):
    delay = 12.0
    token = None
    fail_stage = None
    timeout = 60
    last_request = {}
    jobs = {}
    uploads = {}
    jobs_lock = threading.Lock()

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            return self.reply(200, "text/plain", b"ok\n")
        if self.path.rstrip("/") == "/last":
            return self.reply(200, "application/json", json.dumps(Handler.last_request).encode())
        modes, route = split_mode(self.path)
        path = route.strip("/").split("/")
        if len(path) == 3 and path[0] == "s3":
            return self.read_storage(path[1], path[2])
        if not self.authorized():
            return
        if len(path) == 3 and path[:2] == ["print", "uploads"]:
            if modes.intersection(("legacy", "compat")):
                return self.error(404, "not found")
            return self.confirm_uploads(path[2])
        if len(path) not in (2, 3) or path[0] != "print":
            return self.error(404, "not found")
        with self.jobs_lock:
            job = self.jobs.get(path[1])
        if job is None:
            return self.error(404, "unknown or expired print job")
        if len(path) == 3:
            if path[2] != "result":
                return self.error(404, "not found")
            with job.condition:
                while job.terminal is None:
                    job.condition.wait()
                terminal = job.terminal
            if terminal["type"] == "error":
                return self.error(500, terminal["detail"])
            return self.reply(200, "model/stl", job.stl, {"X-Print-Report": json.dumps(job.report)})
        self.stream(job)

    def read_reference(self, job_id, name, slot):
        if time.time() >= slot.get("read_expires", 0):
            slot.update(read_sig=uuid.uuid4().hex, read_expires=time.time() + UPLOAD_EXPIRES)
        host = self.headers.get("Host", "127.0.0.1:%d" % self.server.server_address[1])
        file_id = f"{job_id}/{name}"
        return {"file_id": file_id, "get_url": f"http://{host}/s3/{file_id}?read={slot['read_sig']}"}

    def confirm_uploads(self, job_id):
        with self.jobs_lock:
            uploads = self.uploads.get(job_id)
            if uploads is None or not uploads.slots.keys() <= uploads.files.keys():
                return self.error(404, "one or more uploads are missing")
            for slot in uploads.slots.values():
                slot["read_expires"] = 0
            references = {name: self.read_reference(job_id, name, slot) for name, slot in uploads.slots.items()}
        self.reply(200, "application/json", json.dumps({"job_id": job_id, "uploads": references}).encode())

    def read_storage(self, job_id, name):
        query = dict(item.split("=", 1) for item in self.path.partition("?")[2].split("&") if "=" in item)
        with self.jobs_lock:
            uploads = self.uploads.get(job_id)
            job = self.jobs.get(job_id)
            if name == "result.stl" and job and job.stl:
                slot, item = job.download_slot, ("model/stl", job.stl)
            else:
                slot = uploads.slots.get(name) if uploads else None
                item = uploads.files.get(name) if uploads else None
        if item is None:
            return self.error(404, "missing object")
        if not slot or self.headers.get("Authorization") or query.get("read") != slot.get("read_sig") or time.time() >= slot.get("read_expires", 0):
            return self.error(403, "invalid or expired read signature")
        self.reply(200, *item)

    def authorized(self):
        if self.token and self.headers.get("Authorization") != "Bearer " + self.token:
            self.close_connection = True
            self.error(401, "missing or invalid token")
            return False
        return True

    def do_PUT(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        query = dict(item.split("=", 1) for item in self.path.partition("?")[2].split("&") if "=" in item)
        if len(parts) != 3 or parts[0] != "s3":
            return self.error(404, "not found")
        job_id, name = parts[1], parts[2]
        with self.jobs_lock:
            uploads = self.uploads.get(job_id)
            slot = uploads.slots.get(name) if uploads else None
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.error(411, "Content-Length required")
        if not 0 <= length <= MAX_UPLOAD_BYTES:
            self.close_connection = True
            return self.reply(413, "application/xml", b"<Error><Code>EntityTooLarge</Code></Error>")
        refusal = None
        if slot is None or query.get("sig") != slot["sig"] or self.headers.get("Authorization"):
            refusal = ("SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided.")
        elif uploads.denied:
            refusal = ("AccessDenied", "User is not authorized to perform: s3:PutObject because no identity-based policy allows the s3:PutObject action")
        elif time.time() > slot["expires"]:
            refusal = ("AccessDenied", "Request has expired")
        else:
            for header, value in slot["headers"].items():
                if self.headers.get(header) != value:
                    refusal = ("SignatureDoesNotMatch", "%s must be %s" % (header, value))
        if refusal or length != slot["size"]:
            # Discard the body without buffering it, so the client still reads the error.
            while length > 0:
                length -= len(self.rfile.read(min(length, 65536)) or b"x" * length)
            if refusal:
                return self.s3_error(uploads, *refusal)
            return self.reply(400, "application/xml", b"<Error><Code>IncompleteBody</Code><Message>size differs from the declared size</Message></Error>")
        body = self.rfile.read(length)
        with self.jobs_lock:
            uploads.files[name] = (slot["content_type"], body)
            uploads.stats["puts"] += 1
        self.log_message("upload %s/%s (%d bytes)", job_id, name, len(body))
        self.reply(200, "application/xml", b"")

    def s3_error(self, uploads, code, message):
        if uploads:
            with self.jobs_lock:
                uploads.stats["rejected_puts"] += 1
        self.reply(403, "application/xml", ("<Error><Code>%s</Code><Message>%s</Message></Error>" % (code, message)).encode())

    def create_uploads(self, modes):
        if "legacy" in modes:
            return self.error(405, "Method Not Allowed")
        try:
            length = int(self.headers.get("Content-Length", ""))
            request = json.loads(self.rfile.read(length))
            files = request["files"]
            assert isinstance(files, dict) and files
        except (ValueError, KeyError, TypeError, AssertionError):
            return self.error(422, "expected JSON {job_id, files: {name: {content_type, size}}}")
        job_id = request.get("job_id") or str(uuid.uuid4())
        host = self.headers.get("Host", "127.0.0.1:%d" % self.server.server_address[1])
        response = {}
        with self.jobs_lock:
            uploads = self.uploads.setdefault(job_id, Uploads())
            uploads.stats["url_requests"] += 1
            uploads.denied = "deny" in modes
            for name, spec in files.items():
                if not is_upload_name(name):
                    return self.error(422, "unknown upload " + name)
                content_type, size = spec.get("content_type"), spec.get("size")
                if not content_type or not isinstance(size, int) or not 0 < size <= MAX_UPLOAD_BYTES:
                    return self.error(422, "%s needs content_type and a size up to %d bytes" % (name, MAX_UPLOAD_BYTES))
                expired = "expire" in modes and name not in uploads.slots
                expires = time.time() + (-1 if expired else UPLOAD_EXPIRES)
                slot = {"sig": uuid.uuid4().hex, "expires": expires, "content_type": content_type, "size": size,
                        "headers": {"Content-Type": content_type, "x-amz-server-side-encryption": "AES256"}}
                uploads.slots[name] = slot
                response[name] = {"url": "http://%s/s3/%s/%s?expires=%d&sig=%s" % (host, job_id, name, expires, slot["sig"]),
                                  "method": "PUT", "headers": slot["headers"]}
                if "compat" not in modes:
                    response[name].update(self.read_reference(job_id, name, slot))
        self.reply(200, "application/json", json.dumps({"job_id": job_id, "expires_in": UPLOAD_EXPIRES, "uploads": response}).encode())

    def attach_uploads(self, parts, modes):
        """Puts a signed upload's stored files into `parts`; returns the 409 missing list, if any."""
        names = [name for name in parts.pop("uploaded")[1].decode().split(",") if name]
        job_id = parts.get("job_id", (None, b""))[1].decode()
        with self.jobs_lock:
            uploads = self.uploads.get(job_id) or Uploads()
            if "drop" in modes and names and not uploads.dropped:
                uploads.dropped = True
                uploads.files.pop(names[0], None)
            missing = [name for name in names if name not in uploads.files]
            if missing:
                uploads.stats["conflicts"] += 1
                return missing, None
            for name in names:
                content_type, data = uploads.files[name]
                filename = "mesh" + MESH_TYPES.get(content_type, ".bin") if name == "mesh" else upload_filename(name)
                parts[name] = (filename, data)
            return [], {"uploaded": names, "upload_stats": dict(uploads.stats)}

    def do_POST(self):
        modes, path = split_mode(self.path)
        if path not in ("/print", "/print/uploads", "/photo-check"):
            return self.error(404, "not found")
        if not self.authorized():
            return
        if path == "/print/uploads":
            return self.create_uploads(modes)
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data"):
            return self.error(400, "expected multipart/form-data")
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.error(411, "Content-Length required")
        if length < 0 or length > MAX_UPLOAD_BYTES:
            self.close_connection = True
            return self.error(413, "upload larger than %d MB" % (MAX_UPLOAD_BYTES // (1024 * 1024)))
        body = self.rfile.read(length)
        parts = parse_multipart(content_type, body)
        upload_summary = {}
        if path == "/print" and "uploaded" in parts:
            if any(is_upload_name(name) for name in parts):
                return self.error(400, "send uploaded files by URL, not as file parts")
            missing, upload_summary = self.attach_uploads(parts, modes)
            if missing:
                return self.reply(409, "application/json", json.dumps({"detail": "upload missing: " + ", ".join(missing), "missing": missing}).encode())
        elif path == "/print":
            with self.jobs_lock:
                earlier = self.uploads.get(parts.get("job_id", (None, b""))[1].decode())
                if earlier:
                    upload_summary = {"upload_stats": dict(earlier.stats)}

        if path == "/photo-check":
            if not parts.get("photo", (None, b""))[1]:
                return self.error(400, "photo is required")
            try:
                result = photo_check(parts)
            except ValueError as error:
                return self.error(422, str(error))
            self.log_message("photo check: %s", json.dumps(result))
            return self.reply(200, "application/json", json.dumps(result).encode())

        if ("mesh" in parts) == ("photo" in parts):
            return self.error(400, "send exactly one of mesh or photo")
        if "mesh" in parts:
            filename, data = parts["mesh"]
            if not filename or not filename.lower().endswith(MESH_EXTENSIONS):
                return self.error(415, "mesh must be an .obj, .ply or .usdz file")
            if not data:
                return self.error(400, "mesh is empty")
            source = "mesh %s (%d bytes)" % (filename, len(data))
            stem = filename.rsplit(".", 1)[0]
        else:
            filename, data = parts["photo"]
            if not filename or not filename.lower().endswith(PHOTO_EXTENSIONS):
                return self.error(415, "photo must be a .jpg or .png file")
            if not data:
                return self.error(400, "photo is empty")
            source = "photo (%d bytes)" % len(data)
            if "height_mm" in parts:
                try:
                    height = float(parts["height_mm"][1].decode())
                except ValueError:
                    height = 0
                if height <= 0:
                    return self.error(422, "height_mm must be a positive number")
                source += ", height %g mm" % height
            summary = {}
            if "camera_transform" in parts or "depth" in parts:
                try:
                    summary.update(check_pose(parts))
                except ValueError as error:
                    return self.error(422, str(error))
            if "depth" in parts:
                try:
                    summary.update(check_depth(parts))
                except ValueError as error:
                    return self.error(422, str(error))
                source += ", depth %(depth_width)dx%(depth_height)d" % summary
            stem = "photo"
            if parts.get("mode", (None, b"object"))[1].decode() == "face":
                try:
                    summary = check_face(parts)
                except ValueError as error:
                    return self.error(422, str(error))
                source = source.replace("photo", "face photo", 1)
                if "depth_width" in summary:
                    source += ", depth %(depth_width)dx%(depth_height)d" % summary
                stem = "face"

        Handler.last_request = {"fields": sorted(parts), "source": source, **upload_summary}
        if "photo" in parts:
            Handler.last_request.update(summary)

        self.log_message("print request: %s", source)
        report = {"extents_mm": [20.0, 20.0, 20.0], "watertight": True, "volume_cm3": 8.0}
        if "application/x-ndjson" in self.headers.get("Accept", ""):
            job_id = parts.get("job_id", (None, b""))[1].decode() or str(uuid.uuid4())
            fail_stage = self.fail_stage or ("repair" if "fail" in modes else None)
            with self.jobs_lock:
                if job_id not in self.jobs:
                    self.jobs[job_id] = Job(job_id, stem, self.delay, fail_stage, bool(modes.intersection(("compat", "legacy"))))
                job = self.jobs[job_id]
            return self.stream(job)
        time.sleep(self.delay)
        self.reply(200, "model/stl", cube_stl(), {
            "Content-Disposition": 'attachment; filename="%s.stl"' % stem,
            "X-Print-Report": json.dumps(report),
        })

    def error(self, status, detail):
        self.reply(status, "application/json", json.dumps({"detail": detail}).encode())

    def line(self, event):
        self.wfile.write((json.dumps(event) + "\n").encode())
        self.wfile.flush()

    def stream(self, job):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.line({"type": "accepted", "job_id": job.id})
            with job.condition:
                cursor = max(0, len(job.events) - 1)
            while True:
                with job.condition:
                    while len(job.events) <= cursor:
                        job.condition.wait(timeout=2)
                    events = job.events[cursor:]
                    cursor = len(job.events)
                for event in events:
                    if event["type"] == "done":
                        if job.inline_stl:
                            event = dict(event, stl_base64=base64.b64encode(job.stl).decode())
                        else:
                            with self.jobs_lock:
                                reference = self.read_reference(job.id, "result.stl", job.download_slot)
                            event = dict(event, stl_url=reference["get_url"], stl_file_id=reference["file_id"],
                                         stl_expires_in=UPLOAD_EXPIRES)
                    self.line(event)
                    if event["type"] in ("done", "error"):
                        return
        except (BrokenPipeError, ConnectionResetError):
            pass

    def reply(self, status, content_type, body, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--delay", type=float, default=12.0, help="total processing seconds; streams heartbeats at least every 2 seconds")
    parser.add_argument("--fail-stage", help="emit a terminal error at this stage (or use /fail as the base URL)")
    parser.add_argument("--token", help="require Authorization: Bearer <token>")
    args = parser.parse_args()
    Handler.delay = args.delay
    Handler.token = args.token
    Handler.fail_stage = args.fail_stage
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("Print stub listening on http://%s:%d/print" % (args.host, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
