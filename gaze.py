"""Webcam gaze dot with a physical 3D model, so it holds up when the head moves in, out and sideways.

Per frame: MediaPipe landmarks -> head pose -> ETH-XGaze face normalization -> UniGaze ensemble
(ViT-H + ViT-L, each with a mirrored pass) -> 3D gaze ray from the face -> intersect the screen plane.
The models are Core ML (convert.py builds them) and run on the Neural Engine, which leaves the GPU alone.
Calibration fits 8 physical numbers (eye-axis offset, angle gain, depth scale, camera position),
not a black-box regression, and includes head-movement passes so depth is actually constrained.

  python gaze.py                 calibrate (or reuse calib.npz) then show the live gaze dot
  python gaze.py --recalibrate   force a new calibration
  python gaze.py --units gpu     run the models on the GPU instead (faster when the GPU is idle, slower when it is not)
  python gaze.py --bench         headless timing, no window
  python gaze.py --serve         no window: answer "where are they looking?" on a local socket (what micbtn asks)
  python gaze.py --serve --glow  the same, following the eyes all the time, with a small dot in the corner of the Ghostty (or iTerm) pane looked at
  python gaze.py --point         ask the running --serve daemon once and print its answer
  python gaze.py --demo 14       a target to follow with your eyes, the gaze dot chasing it (--record clip.mov)
Keys: Esc quit, C recalibrate everything, U recalibrate the external screen only, F toggle smoothing.
With an external monitor connected it opens a window on both screens and fits where that monitor sits in space.
"""
import argparse, os, time, threading, math
import numpy as np, cv2
from scipy.optimize import least_squares

STATE = os.path.expanduser("~/Library/Application Support/gaze")  # calibration, model assets, the daemon's socket
SOCK = os.path.join(STATE, "gaze.sock")
os.makedirs(STATE, exist_ok=True)
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
MP6 = [33, 133, 362, 263, 98, 327]  # dlib-68 points 36,39,42,45 (eye corners), 31,35 (nostril base)
IRIS = [468, 473]


def builtin_camera():
    """OpenCV numbers cameras by sorted unique id, so an iPhone nearby shifts the built-in one. Find it by name."""
    import json, subprocess
    try:
        cams = json.loads(subprocess.run(["system_profiler", "SPCameraDataType", "-json"], capture_output=True, timeout=10).stdout)["SPCameraDataType"]
        cams.sort(key=lambda c: c.get("spcamera_unique-id", ""))
        for i, c in enumerate(cams):
            if not c.get("spcamera_model-id", "").startswith("iPhone"):
                return i
    except Exception:
        pass
    return 0


class Camera:
    """Keeps only the newest frame so inference never works on a stale one."""

    def __init__(self, index):
        self.index, self.n, self.cap = index, 0, None
        self.open()

    def open(self):
        if self.cap is not None:
            return
        self.cap = cv2.VideoCapture(self.index)
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
        self.frame, self.ok = None, True
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def close(self):
        """Lets go of the camera (its light goes out) until open()."""
        if self.cap is None:
            return
        self.ok = False
        self.thread.join(2)
        self.cap.release()
        self.cap = None

    def _run(self):
        while self.ok:
            ok, f = self.cap.read()
            if ok:
                self.frame, self.n = f, self.n + 1

    def latest(self, last_n, timeout=None):
        t0 = time.time()
        while self.n == last_n or self.frame is None:
            if timeout and time.time() - t0 > timeout:
                raise TimeoutError("no frame from the camera")
            time.sleep(0.001)
        return self.frame, self.n


class OneEuro:
    def __init__(self, mincutoff=0.6, beta=0.004, dcutoff=1.0):
        self.mc, self.beta, self.dc, self.x, self.dx, self.t = mincutoff, beta, dcutoff, None, 0, None

    def __call__(self, x, t):
        if self.x is None:
            self.x, self.t = x, t; return x
        dt = max(t - self.t, 1e-3); self.t = t
        a = lambda c: 1 / (1 + 1 / (2 * math.pi * c * dt))
        dx = (x - self.x) / dt
        self.dx = self.dx + a(self.dc) * (dx - self.dx)
        cutoff = self.mc + self.beta * np.linalg.norm(self.dx)
        self.x = self.x + a(cutoff) * (x - self.x)
        return self.x


class Gaze:
    """A camera frame to a gaze direction: (pitch, yaw) in the normalized face view, plus the head's place.

    The answer is the mean of four passes: ViT-H and ViT-L, each on the face and on its mirror image.
    A cheaper subset of them differs from that mean by a slowly changing offset (measured: 0.3 to 0.7
    degrees, with 0.2 to 0.5 degrees of scatter left once it is removed). So every frame runs only the
    cheap passes and adds the offset, and every `refresh_every` seconds one face is put through the rest,
    one pass a frame so no frame stalls, to bring the offset up to date.

    cheap = both straight passes (72 ms on the Neural Engine): calibration and the live view.
    light = ViT-L alone (17 ms): the daemon when it follows the eyes, where speed matters more than the
            last half degree and a click is the median of several frames anyway.
    """

    def __init__(self, units="ne", light=False):
        import coremltools as ct, mediapipe as mp
        from mediapipe.tasks import python as mpt
        from mediapipe.tasks.python import vision
        self.mp = mp
        missing = [n for n in ("h14", "l16") if not os.path.isdir(os.path.join(STATE, n + ".mlmodelc"))]
        if missing:
            raise SystemExit("the Core ML models are not built: run  ./install.sh")
        cu = ct.ComputeUnit.CPU_AND_GPU if units == "gpu" else ct.ComputeUnit.CPU_AND_NE
        self.models = [ct.models.CompiledMLModel(os.path.join(STATE, n + ".mlmodelc"), compute_units=cu) for n in ("h14", "l16")]
        self.cheap = [1] if light else [0, 1]
        self.refresh_every = 3.0 if light else 1.0
        self.offset, self.refreshed, self.refreshes, self.job = np.zeros(2), 0.0, 0, None
        self.fm = np.loadtxt(os.path.join(STATE, "face_model.txt"))[[20, 23, 26, 29, 15, 19], :]
        opts = vision.FaceLandmarkerOptions(
            base_options=mpt.BaseOptions(model_asset_path=os.path.join(STATE, "face_landmarker.task")),
            running_mode=vision.RunningMode.VIDEO, num_faces=1, output_face_blendshapes=True)
        self.lm = vision.FaceLandmarker.create_from_options(opts)
        self.t0 = time.time()
        self.cfilt = OneEuro(mincutoff=1.0, beta=0.02)  # head position is slow; landmark depth is noisy

    def __call__(self, frame):
        """Returns dict(s, lms, blink, norm) or None when no face. s = [centre xyz mm, pitch, yaw, head x-axis]."""
        h, w = frame.shape[:2]
        img = self.mp.Image(image_format=self.mp.ImageFormat.SRGB, data=cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        res = self.lm.detect_for_video(img, int((time.time() - self.t0) * 1000))
        if not res.face_landmarks:
            return None
        lms = np.array([[p.x * w, p.y * h] for p in res.face_landmarks[0]], np.float64)
        blink = 0.0
        if res.face_blendshapes:
            bs = {b.category_name: b.score for b in res.face_blendshapes[0]}
            blink = max(bs.get("eyeBlinkLeft", 0), bs.get("eyeBlinkRight", 0))

        cam = np.array([[w, 0, w / 2], [0, w, h / 2], [0, 0, 1]], np.float64)  # focal guess; calibration rescales depth
        dist = np.zeros((1, 5))
        pts2, pts3 = lms[MP6].reshape(6, 1, 2), self.fm.reshape(6, 1, 3)
        _, hr, ht = cv2.solvePnP(pts3, pts2, cam, dist, flags=cv2.SOLVEPNP_EPNP)
        _, hr, ht = cv2.solvePnP(pts3, pts2, cam, dist, hr, ht, True)
        hR = cv2.Rodrigues(hr)[0]
        Fc = (hR @ self.fm.T + ht).T
        center = ((Fc[:4].mean(0) + Fc[4:].mean(0)) / 2).reshape(3)
        center = self.cfilt(center, time.time())

        # ETH-XGaze normalization: virtual camera 600 mm from the face, f=960, 224 px
        d = np.linalg.norm(center)
        cam_n = np.array([[960, 0, 112], [0, 960, 112], [0, 0, 1.0]])
        fwd = center / d
        down = np.cross(fwd, hR[:, 0]); down /= np.linalg.norm(down)
        right = np.cross(down, fwd); right /= np.linalg.norm(right)
        R = np.c_[right, down, fwd].T
        W = cam_n @ np.diag([1.0, 1.0, 600.0 / d]) @ R @ np.linalg.inv(cam)
        norm = cv2.warpPerspective(frame, W, (224, 224))

        x = (norm[:, :, ::-1].astype(np.float32) / 255 - MEAN) / STD
        x = np.ascontiguousarray(x.transpose(2, 0, 1)[None])
        got = {(i, False): self.models[i].predict({"x": x})["gaze"][0] for i in self.cheap}
        cheap = np.mean(list(got.values()), 0)
        if self.job is None and time.time() - self.refreshed >= self.refresh_every:
            todo = [(i, m) for m in (False, True) for i in range(len(self.models)) if (i, m) not in got]
            self.job = dict(x=x, cheap=cheap, got=got, todo=todo)
        elif self.job is not None:  # one more pass of the face the refresh started on
            job = self.job
            i, mirrored = job["todo"].pop(0)
            r = self.models[i].predict({"x": np.ascontiguousarray(job["x"][..., ::-1]) if mirrored else job["x"]})["gaze"][0]
            job["got"][(i, mirrored)] = r * [1, -1] if mirrored else r  # a mirrored face: same pitch, opposite yaw
            if not job["todo"]:
                full = np.mean(list(job["got"].values()), 0)
                self.refreshes += 1
                self.offset += (full - job["cheap"] - self.offset) * max(0.25, 1 / self.refreshes)  # plain mean at first, then a running one
                self.refreshed, self.job = time.time(), None
        pitch, yaw = cheap + self.offset
        s = np.r_[center, pitch, yaw, hR[:, 0]]
        return dict(s=s, lms=lms, blink=blink, norm=norm)


class PhysMapper:
    """Screen point = (face centre) + t * (gaze direction), intersected with the screen plane.

    Parameters: pitch/yaw offset (the eye's optical-vs-visual axis), pitch/yaw gain, lateral and depth
    scale of the head position (unknown focal length and face size), camera offset on the screen in px.
    """
    P0 = np.array([0, 0, 1, 1, 0, 0, 0, 0], np.float64)
    PRIOR_W = np.array([0, 0, 250, 250, 80, 25, 0.3, 0.3])  # px of penalty per unit away from P0

    def __init__(self, sw, sh, ppm):
        self.sw, self.sh, self.ppm = sw, sh, ppm
        self.p, self.sx = self.P0.copy(), -1.0

    def _geom(self, p, S):
        S = np.atleast_2d(S)
        c = S[:, :3] * np.array([math.exp(p[4]), math.exp(p[4]), math.exp(p[5])])
        fwd = c / np.linalg.norm(c, axis=1, keepdims=True)
        down = np.cross(fwd, S[:, 5:8]); down /= np.linalg.norm(down, axis=1, keepdims=True)
        right = np.cross(down, fwd); right /= np.linalg.norm(right, axis=1, keepdims=True)
        pitch, yaw = p[2] * S[:, 3] + p[0], p[3] * S[:, 4] + p[1]
        v = np.c_[np.cos(pitch) * np.sin(yaw), np.sin(pitch), np.cos(pitch) * np.cos(yaw)]
        g = -(right * v[:, :1] + down * v[:, 1:2] + fwd * v[:, 2:3])
        hit = c - (c[:, 2:3] / g[:, 2:3]) * g
        return c, hit, g

    def rays(self, S):
        c, _, g = self._geom(self.p, S)
        return c, g

    def _px(self, p, S, sx):
        _, hit, _ = self._geom(p, S)
        return np.c_[self.sw / 2 + p[6] + sx * self.ppm * hit[:, 0], p[7] + self.ppm * hit[:, 1]]

    def predict(self, S):
        return self._px(self.p, S, self.sx)

    def distance_cm(self, s):
        return float(np.linalg.norm(self._geom(self.p, s)[0])) / 10

    def fit(self, S, Y):
        rn = math.sqrt(len(S))
        def res(p, sx):
            return np.r_[(self._px(p, S, sx) - Y).ravel(), rn * self.PRIOR_W * (p - self.P0)]
        best = None
        for sx in (-1.0, 1.0):
            r = least_squares(res, self.P0, args=(sx,), loss="soft_l1", f_scale=60)
            if best is None or r.cost < best[0].cost:
                best = (r, sx)
        self.p, self.sx = best[0].x, best[1]
        return self

    def save(self, path):
        np.savez(path, p=self.p, sx=self.sx)

    def load(self, path):
        d = np.load(path); self.p, self.sx = d["p"], float(d["sx"]); return self


class Plane:
    """A second screen as a rigid rectangle somewhere in the camera frame: 3 rotation + 3 position numbers.

    Its physical size is known (EDID), so dots shown on it plus the already-calibrated gaze rays pin down its pose.
    """
    R0 = np.array([[-1.0, 0, 0], [0, 1, 0], [0, 0, -1]])  # columns: screen-right, screen-down, normal (camera x is the user's left)

    def __init__(self, w, h, ppm):
        self.w, self.h, self.ppm, self.q = w, h, ppm, np.zeros(6)

    def _px(self, q, c, g):
        Rm = cv2.Rodrigues(np.asarray(q[:3], np.float64))[0] @ self.R0
        T, nrm = np.asarray(q[3:]), Rm[:, 2]
        t = ((T - c) @ nrm) / (g @ nrm)
        loc = (c + t[:, None] * g - T) @ Rm
        px = np.c_[self.w / 2 + self.ppm * loc[:, 0], self.h / 2 + self.ppm * loc[:, 1]]
        px[t <= 0] = 1e6  # looking away from it
        return px

    def predict(self, c, g):
        return self._px(self.q, c, g)

    def fit(self, c, g, Y):
        best = None
        for rx in (-0.5, -0.25, 0, 0.25, 0.5):
            for tz in (100, -100, -350):
                q0 = np.array([rx, 0, 0, 0, -(self.h / self.ppm / 2 + 60), tz])
                r = least_squares(lambda q: np.clip(self._px(q, c, g) - Y, -5000, 5000).ravel(), q0, loss="soft_l1", f_scale=100)
                if best is None or r.cost < best.cost:
                    best = r
        self.q = best.x
        return self

    def save(self, path):
        np.savez(path, q=self.q)

    def load(self, path):
        self.q = np.load(path)["q"]; return self


# ---------------------------------------------------------------- native windows, one per monitor
import AppKit, Quartz
from Foundation import NSData, NSDate


class KeyWindow(AppKit.NSWindow):
    def canBecomeKeyWindow(self):
        return True


class Display:
    """A borderless window covering one monitor. Canvases are drawn at `scale` of its point size."""

    def __init__(self, screen, scale, window=True):
        did = screen.deviceDescription()["NSScreenNumber"]
        f = screen.frame()
        self.w, self.h, self.scale = int(f.size.width), int(f.size.height), scale
        self.builtin = bool(Quartz.CGDisplayIsBuiltin(did))
        self.ppm = self.w / Quartz.CGDisplayScreenSize(did).width
        b = Quartz.CGDisplayBounds(did)
        self.ox, self.oy = b.origin.x, b.origin.y  # top-left in the global coordinates mouse events use
        if not window:
            return
        self.win = KeyWindow.alloc().initWithContentRect_styleMask_backing_defer_(f, 0, 2, False)
        self.win.setLevel_(1000)
        self.win.setOpaque_(True)
        self.win.setBackgroundColor_(AppKit.NSColor.blackColor())
        self.win.setCollectionBehavior_((1 << 0) | (1 << 4))
        self.win.contentView().setWantsLayer_(True)
        self.layer = self.win.contentView().layer()
        self.layer.setContentsGravity_("resize")
        self.win.orderFrontRegardless()
        self.cs = Quartz.CGColorSpaceCreateDeviceRGB()

    def canvas(self, bg=0):
        return np.full((int(self.h * self.scale), int(self.w * self.scale), 3), bg, np.uint8)

    def P(self, x, y):
        return int(x * self.scale), int(y * self.scale)

    def circle(self, cv, x, y, r, color, th=-1):
        cv2.circle(cv, self.P(x, y), max(1, int(r * self.scale)), color, th if th < 0 else max(1, int(th * self.scale)), cv2.LINE_AA)

    def text(self, cv, s, y, color=(170, 170, 170), size=0.7, x=30):
        k = max(self.scale, 0.5) * (1.6 if not self.builtin else 1.0)
        cv2.putText(cv, s, self.P(x, y), cv2.FONT_HERSHEY_SIMPLEX, size * k, color, 2, cv2.LINE_AA)

    def show(self, cv):
        rgba = cv2.cvtColor(cv, cv2.COLOR_BGR2RGBA)
        h, w = rgba.shape[:2]
        prov = Quartz.CGDataProviderCreateWithCFData(NSData.dataWithBytes_length_(rgba.tobytes(), w * h * 4))
        img = Quartz.CGImageCreate(w, h, 8, 32, w * 4, self.cs, Quartz.kCGImageAlphaNoneSkipLast, prov, None, False, 0)
        Quartz.CATransaction.begin(); Quartz.CATransaction.setDisableActions_(True)
        self.layer.setContents_(img)
        Quartz.CATransaction.commit()


def outside_mm(p, D):
    """How far a point is off a display, in millimetres (0 when on it)."""
    return max(0.0, -p[0], p[0] - D.w, -p[1], p[1] - D.h) / D.ppm


class Scr:
    """One monitor as the daemon needs it: size, position on the desktop, pixels per millimetre."""

    def __init__(self, did):
        b = Quartz.CGDisplayBounds(did)
        self.w, self.h, self.ox, self.oy = int(b.size.width), int(b.size.height), b.origin.x, b.origin.y
        self.builtin = bool(Quartz.CGDisplayIsBuiltin(did))
        self.ppm = self.w / max(Quartz.CGDisplayScreenSize(did).width, 1.0)


class Tracker:
    """The screens and the calibration, re-read when either changes: a monitor plugged in, a recalibration."""
    CAL, EXT = os.path.join(STATE, "calib.npz"), os.path.join(STATE, "calib_ext.npz")

    def __init__(self):
        self.sig = self.stamp = self.lap = self.ext = self.mapper = self.plane = None
        self.checked = 0.0

    def refresh(self):
        now = time.time()
        if now - self.checked < 1:
            return
        self.checked = now
        _, ids, _ = Quartz.CGGetActiveDisplayList(8, None, None)
        ds = [Scr(d) for d in ids]
        sig = tuple((d.w, d.h, d.ox, d.oy, d.builtin) for d in ds)
        stamp = tuple(os.path.getmtime(p) if os.path.exists(p) else 0 for p in (self.CAL, self.EXT))
        if sig == self.sig and stamp == self.stamp:
            return
        self.sig, self.stamp = sig, stamp
        self.lap = next((d for d in ds if d.builtin), None)
        self.ext = next((d for d in ds if not d.builtin), None)
        self.mapper = PhysMapper(self.lap.w, self.lap.h, self.lap.ppm).load(self.CAL) if self.lap and stamp[0] else None
        self.plane = Plane(self.ext.w, self.ext.h, self.ext.ppm).load(self.EXT) if self.mapper and self.ext and stamp[1] else None
        print("screens: " + (f"laptop {self.lap.w}x{self.lap.h}" if self.lap else "no laptop screen (lid closed?)")
              + (f", external {self.ext.w}x{self.ext.h}" + ("" if self.plane else " (not calibrated)") if self.ext else ""), flush=True)

    def estimate(self, out):
        """(name, x, y) in global screen points, or None when the gaze is off every calibrated screen."""
        if self.mapper is None:
            return None
        cand = {self.lap: self.mapper.predict(out["s"])[0]}
        if self.plane is not None:
            c, g = self.mapper.rays(out["s"])
            cand[self.ext] = self.plane.predict(c, g)[0]
        D = min(cand, key=lambda d: outside_mm(cand[d], d))
        if outside_mm(cand[D], D) > 60:
            return None
        p = np.clip(cand[D], [2, 2], [D.w - 3, D.h - 3])
        return ("laptop" if D is self.lap else "external", D.ox + p[0], D.oy + p[1])


TERMINALS = ("Ghostty", "iTerm2")  # both show a pane as an AXTextArea inside an AXScrollArea


class Glow:
    """A small dot in the bottom-left corner of the terminal pane being looked at (Ghostty or iTerm). A click-through window of its
    own, so the terminal is not touched. (It was a ring around the whole pane; that was too much to look at all day.)

    The panes come from Accessibility (each session is an AXTextArea inside an AXScrollArea), which is the
    only place either terminal says where a pane is on screen. The daemon runs as MicBtn's child, so MicBtn's
    Accessibility grant covers it.
    """
    M, D, INSET = 8, 7, 9  # room around the dot for its glow, its diameter, and how far in from the pane's corner

    def __init__(self):
        import ApplicationServices as AS
        self.AS = AS
        app = AppKit.NSApplication.sharedApplication()
        app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)
        app.finishLaunching()
        w = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(((0, 0), (100, 100)), 0, 2, False)
        w.setReleasedWhenClosed_(False)
        w.setOpaque_(False); w.setBackgroundColor_(AppKit.NSColor.clearColor()); w.setHasShadow_(False)
        w.setIgnoresMouseEvents_(True)
        w.setLevel_(3)  # floating: above ordinary windows, below menus
        w.setCollectionBehavior_((1 << 0) | (1 << 4) | (1 << 6) | (1 << 8))  # every Space, fullscreen ones too; never in Cmd-`
        w.contentView().setWantsLayer_(True)
        dot = Quartz.CALayer.layer()
        color = Quartz.CGColorCreateGenericRGB(0.45, 0.78, 1.0, 0.75)
        dot.setBackgroundColor_(color); dot.setCornerRadius_(self.D / 2)
        dot.setShadowColor_(color); dot.setShadowRadius_(4); dot.setShadowOpacity_(0.9); dot.setShadowOffset_((0, 0))
        dot.setFrame_(((self.M, self.M), (self.D, self.D)))
        w.contentView().layer().addSublayer_(dot)
        self.win = w
        self.current = self.pending = None
        self.since, self.count = 0.0, 0
        self.cache = {}  # pid -> (when, panes)
        if not AS.AXIsProcessTrusted():
            print("glow: no Accessibility, so the terminal's panes cannot be read: turn on MicBtn under Privacy & Security > Accessibility", flush=True)

    def _ax(self, el, attr):
        err, v = self.AS.AXUIElementCopyAttributeValue(el, attr, None)
        return v if err == 0 else None

    def _frame(self, el):
        pos, size = self._ax(el, "AXPosition"), self._ax(el, "AXSize")
        if pos is None or size is None:
            return None
        _, p = self.AS.AXValueGetValue(pos, self.AS.kAXValueCGPointType, None)
        _, z = self.AS.AXValueGetValue(size, self.AS.kAXValueCGSizeType, None)
        return (int(p.x), int(p.y), int(z.width), int(z.height))

    def panes(self, pid):
        """Every visible session's frame in global screen points, re-read at most every 0.7 s."""
        when, panes = self.cache.get(pid, (0, []))
        if time.time() - when < 0.7:
            return panes
        app, panes = self.AS.AXUIElementCreateApplication(pid), []
        self.AS.AXUIElementSetMessagingTimeout(app, 0.3)  # a busy terminal never stalls the tracker

        def walk(el, parent, depth):
            role = self._ax(el, "AXRole")
            if role == "AXTextArea":
                f = self._frame(parent if parent is not None and self._ax(parent, "AXRole") == "AXScrollArea" else el)
                if f and f[2] > 40 and f[3] > 40:
                    panes.append(f)
                return
            if depth < 14:
                for c in self._ax(el, "AXChildren") or []:
                    walk(c, el, depth + 1)

        for w in self._ax(app, "AXWindows") or []:
            walk(w, None, 0)
        self.cache[pid] = (time.time(), panes)
        return panes

    def pane_at(self, x, y):
        """The terminal pane under a point, when Ghostty or iTerm is the window showing there. Near misses snap to the closest."""
        opts = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
        for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []:  # front to back
            b = w.get("kCGWindowBounds")
            if w.get("kCGWindowLayer") != 0 or not b or not (b["X"] <= x < b["X"] + b["Width"] and b["Y"] <= y < b["Y"] + b["Height"]):
                continue
            if w.get("kCGWindowOwnerName") not in TERMINALS:
                return None
            best, gap = None, 60.0
            for p in self.panes(w["kCGWindowOwnerPID"]):
                d = max(p[0] - x, x - (p[0] + p[2]), p[1] - y, y - (p[1] + p[3]), 0)
                if d < gap:
                    best, gap = p, d
            return best
        return None

    def update(self, look):
        """Follow the gaze, look by look: two looks in a row on another pane move the dot (about 0.1 s at
        20 a second), and losing it altogether takes half a second, longer than a blink."""
        now = time.time()
        cand = self.pane_at(look[1], look[2]) if look else None
        if cand == self.pending:
            self.count += 1
        else:
            self.pending, self.since, self.count = cand, now, 1
        if self.pending != self.current and (self.count >= 2 if cand else now - self.since >= 0.5):
            self.current = self.pending
            self.show(self.current)
        return self.current

    def show(self, rect):
        if rect is None:
            return self.win.orderOut_(None)
        x, y, w, h = rect
        top, side = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID()).size.height, self.D + 2 * self.M
        # Cocoa counts up from the bottom of the main display; the pane's frame counts down from its top.
        self.win.setFrame_display_(((x + self.INSET - self.M, top - (y + h) + self.INSET - self.M), (side, side)), True)
        self.win.orderFrontRegardless()


def serve(cam, gaze, a):
    """Headless daemon. Any request on the socket is answered with one line: "x y laptop|external" in global
    screen points (what a mouse event takes), or "none <why>".

    Plain --serve infers only when asked (about 0.3 s an answer). With --track or --glow it follows the eyes
    all the time, so an answer is the fixation of the last 0.3 s and comes back at once; it backs off to one
    look a second while nobody is there and stops while the display sleeps."""
    import select, socket
    tr = Tracker(); tr.refresh()
    if tr.mapper is None:
        print("not calibrated (or no laptop screen): run  gaze  once; trying again in 30 s", flush=True)
        time.sleep(30)  # launchd restarts it; no socket means micbtn skips the click
        return
    try:
        cam.latest(0, timeout=10)
    except TimeoutError:
        print("the camera gave no frame (no Camera permission, or it is in use): exiting to be restarted", flush=True)
        os._exit(1)
    track = a.track or a.glow
    glow = Glow() if a.glow else None
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK); os.chmod(SOCK, 0o600); srv.listen(4)
    print(f"serving on {SOCK}" + (f", tracking at up to {a.fps:g} fps" if track else ", on demand") + (", a dot on the terminal pane looked at" if glow else ""), flush=True)
    hist, why, seen = [], "no-face", time.time()
    # MicBtn, which runs this daemon, says when a call starts and ends (micbtn/Call.swift): the camera is
    # let go for as long as it lasts, and every answer is "none in-call".
    import signal
    call = {"on": False}
    signal.signal(signal.SIGUSR1, lambda *_: call.update(on=True))
    signal.signal(signal.SIGUSR2, lambda *_: call.update(on=False))

    def look():
        """One camera frame through the model, into the history."""
        nonlocal why, seen
        frame, _ = cam.latest(cam.n, timeout=1.5)
        out = gaze(frame)
        if out is None or out["blink"] >= 0.5:
            why = "no-face"
            return
        seen = time.time()
        e = tr.estimate(out)
        if e is None:
            why = "off-screen"
        else:
            hist.append((time.time(),) + e)
            del hist[:-40]

    def fixation(window=0.3):
        now = time.time()
        pts = [h for h in hist if now - h[0] <= window]
        if not pts:
            return None
        names = [p[1] for p in pts]
        name = max(set(names), key=names.count)
        return (name, float(np.median([p[2] for p in pts if p[1] == name])), float(np.median([p[3] for p in pts if p[1] == name])))

    try:
        while True:
            t0 = time.time()
            tr.refresh()
            asleep = bool(Quartz.CGDisplayIsAsleep(Quartz.CGMainDisplayID())) or tr.mapper is None
            if call["on"] and cam.cap is not None:
                cam.close(); hist.clear(); why = "in-call"
                print(f"{time.strftime('%H:%M:%S')} in a call: the camera is released", flush=True)
            elif not call["on"] and cam.cap is None:
                cam.open(); why = "no-face"
                print(f"{time.strftime('%H:%M:%S')} the call is over: the camera is back", flush=True)
            asleep = asleep or call["on"]
            pane = None
            if track and not asleep:
                look()
                fresh = hist[-1][1:] if hist and time.time() - hist[-1][0] < 0.2 else None
                pane = glow.update(fresh) if glow else None
            elif glow:
                glow.update(None)
            if glow:
                poll_key()  # lets AppKit draw
            away = t0 - seen > 3
            period = (1.0 if away or asleep else 1.0 / a.fps) if track else 0.5
            ready, _, _ = select.select([srv], [], [], max(0.0, period - (time.time() - t0)))
            if not ready:
                continue
            conn, _ = srv.accept()
            t1 = time.time()
            try:
                conn.settimeout(2); conn.recv(64)
                fix = fixation()
                if fix is None and not asleep:  # on demand, or nobody was there a moment ago
                    for _ in range(a.frames):
                        look()
                    fix = fixation()
                if fix is None:
                    ans = "none " + why
                else:
                    name, x, y = fix
                    if pane:  # the pane with the dot is the one that gets the click
                        x, y = min(max(x, pane[0] + 24), pane[0] + pane[2] - 24), min(max(y, pane[1] + 24), pane[1] + pane[3] - 24)
                    ans = f"{x:.0f} {y:.0f} {name}"
                conn.sendall((ans + "\n").encode())
                print(f"{time.strftime('%H:%M:%S')} {ans} ({1000 * (time.time() - t1):.0f} ms)", flush=True)
            except TimeoutError:
                raise
            except Exception as e:
                print(f"request failed: {e!r}", flush=True)
            finally:
                conn.close()
    except TimeoutError:
        print("the camera stopped giving frames: exiting to be restarted", flush=True)
    finally:
        cam.ok = False
        if os.path.exists(SOCK): os.unlink(SOCK)
        os._exit(1)


def open_displays(laptop_only=False):
    app = AppKit.NSApplication.sharedApplication()
    app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyRegular)
    app.finishLaunching()
    builtin = lambda s: Quartz.CGDisplayIsBuiltin(s.deviceDescription()["NSScreenNumber"])
    ds = [Display(s, 1.0 if builtin(s) else 0.5) for s in AppKit.NSScreen.screens() if builtin(s) or not laptop_only]
    lap = next(d for d in ds if d.builtin)
    ext = next((d for d in ds if not d.builtin), None)
    lap.win.makeKeyAndOrderFront_(None)
    app.activateIgnoringOtherApps_(True)
    return lap, ext


def poll_key():
    """Pump the macOS event queue; return 'esc', 'space', a lowercase letter, or None."""
    app, key = AppKit.NSApp(), None
    while True:
        ev = app.nextEventMatchingMask_untilDate_inMode_dequeue_(AppKit.NSEventMaskAny, NSDate.distantPast(), AppKit.NSDefaultRunLoopMode, True)
        if ev is None:
            return key
        if ev.type() == AppKit.NSEventTypeKeyDown:
            key = {53: "esc", 49: "space"}.get(ev.keyCode()) or (ev.charactersIgnoringModifiers() or "").lower()
        else:
            app.sendEvent_(ev)


def inset(D, canvas, frame, out, size=360):
    """Mirrored camera view in the top-right corner with eye and iris marks."""
    h, w = frame.shape[:2]
    view = frame.copy()
    if out is not None:
        for i in MP6[:4]:
            cv2.circle(view, tuple(out["lms"][i].astype(int)), 5, (0, 255, 255), -1)
        for i in IRIS:
            cv2.circle(view, tuple(out["lms"][i].astype(int)), 9, (0, 255, 0), 2)
    size = int(size * D.scale)
    view = cv2.flip(cv2.resize(view, (size, int(size * h / w))), 1)
    vh, vw = view.shape[:2]
    canvas[20:20 + vh, canvas.shape[1] - vw - 20:canvas.shape[1] - 20] = view
    if out is not None:
        canvas[30 + vh:30 + vh + 112, canvas.shape[1] - 132:canvas.shape[1] - 20] = cv2.resize(out["norm"], (112, 112))


def collect(cam, gaze, D, other, static, moving, intro):
    """Show dots on display D and gather gaze samples. Returns (S, Y, tag) or None on Esc."""
    S, Y, tag, n = [], [], [], 0
    if other is not None:
        cv = other.canvas(); other.text(cv, "Calibrating the other screen - look there.", other.h // 2, (120, 120, 120), 0.9); other.show(cv)
    while True:  # wait for a face, then space
        frame, n = cam.latest(n); out = gaze(frame)
        cv = D.canvas(); inset(D, cv, frame, out)
        for i, line in enumerate(intro):
            D.text(cv, line, D.h // 2 - 60 + 40 * i, (230, 230, 230), 0.9)
        D.text(cv, "Press SPACE to start (Esc to quit)." if out else "No face found - get in view of the camera.", D.h // 2 - 60 + 40 * len(intro) + 20, (0, 220, 255), 0.9)
        D.show(cv); k = poll_key()
        if k == "esc": return None
        if k == "space" and out: break

    def run_point(pt, settle, dur, label, t):
        nonlocal n
        px, py = pt[0] * D.w, pt[1] * D.h
        t0, got = time.time(), []
        while True:
            el = time.time() - t0
            if el > settle + dur: break
            frame, n = cam.latest(n); out = gaze(frame)
            cv = D.canvas()
            frac = min(max((el - settle) / dur, 0), 1)
            D.circle(cv, px, py, 34 - 22 * frac, (0, 0, 255) if el < settle else (0, 200, 255), 3)
            D.circle(cv, px, py, 6, (255, 255, 255))
            if label:
                D.text(cv, label, D.h - 40, (0, 220, 255), 0.9)
            D.show(cv)
            if poll_key() == "esc": return False
            if out is not None and el > settle and out["blink"] < 0.4:
                got.append(out["s"])
        got = np.array(got)
        if len(got) >= 5 and not label:  # static point: drop frames where the eyes wandered
            dev = np.linalg.norm(got[:, 3:5] - np.median(got[:, 3:5], 0), axis=1)
            got = got[dev <= np.median(dev) * 2.5 + 1e-4]
        S.extend(got); Y.extend([(px, py)] * len(got)); tag.extend([t] * len(got))
        return True

    for pt in static:
        if not run_point(pt, 1.0, 1.2, None, 0): return None
    for pt in moving:
        if not run_point(pt, 1.2, 8.0, "Keep staring at the dot: lean IN close, lean BACK, slide LEFT, slide RIGHT", 1): return None
    return np.array(S), np.array(Y, np.float64), np.array(tag)


M = 0.06
GRID9 = [(0.5, 0.5), (M, M), (1 - M, M), (1 - M, 1 - M), (M, 1 - M), (0.5, M), (1 - M, 0.5), (0.5, 1 - M), (M, 0.5)]


def calibrate_laptop(cam, gaze, lap, ext):
    got = collect(cam, gaze, lap, ext, GRID9, [(0.5, 0.5), (0.2, 0.25), (0.8, 0.75)], [
        "Laptop screen. Step 1: 9 dots. Look at the centre of each until it moves, head still.",
        "Step 2: 3 dots. Keep staring at the dot while you slowly lean in, lean back, and slide left and right."])
    if got is None: return None
    S, Y, tag = got
    mapper = PhysMapper(lap.w, lap.h, lap.ppm).fit(S, Y)
    err = np.linalg.norm(mapper.predict(S) - Y, axis=1)
    rep = f"laptop fit: still {np.median(err[tag == 0]):.0f} px, moving {np.median(err[tag == 1]):.0f} px ({np.median(err[tag == 1]) / lap.ppm / 10:.1f} cm)"
    mapper.save(os.path.join(STATE, "calib.npz"))
    with open(os.path.join(STATE, "calib.txt"), "w") as f: f.write(rep)
    print(rep, "| params", np.round(mapper.p, 3), "sx", mapper.sx, flush=True)
    return mapper, rep


def calibrate_ext(cam, gaze, lap, ext, mapper):
    got = collect(cam, gaze, ext, lap, GRID9, [(0.5, 0.5), (0.25, 0.7)], [
        "This screen now. Step 1: 9 dots, look at each until it moves. Turn your head naturally.",
        "Step 2: 2 dots. Keep staring at the dot while you lean in, lean back, and slide left and right."])
    if got is None: return None
    S, Y, tag = got
    c, g = mapper.rays(S)
    plane = Plane(ext.w, ext.h, ext.ppm).fit(c, g, Y)
    err = np.linalg.norm(plane.predict(c, g) - Y, axis=1)
    rep = f"external fit: still {np.median(err[tag == 0]):.0f} px, moving {np.median(err[tag == 1]):.0f} px ({np.median(err[tag == 1]) / ext.ppm / 10:.1f} cm)"
    plane.save(os.path.join(STATE, "calib_ext.npz"))
    np.savez(os.path.join(STATE, "calib_ext_samples.npz"), S=S, Y=Y, tag=tag)
    with open(os.path.join(STATE, "calib_ext.txt"), "w") as f: f.write(rep)
    print(rep, "| tilt deg", np.round(np.degrees(plane.q[:3]), 1), "centre mm", np.round(plane.q[3:]), flush=True)
    return plane, rep


def demo(cam, gaze, lap, mapper, seconds, record):
    """A target glides around the laptop screen and the gaze dot chases it: what the README's clip shows.
    No camera image is drawn, so a recording of it has no face in it. `record` is a .mov path to record
    the laptop screen to for exactly the part after the countdown (needs Screen Recording for the terminal)."""
    import subprocess
    filt, trail, errs, n, rec = OneEuro(mincutoff=1.2, beta=0.01), [], [], 0, None
    path = lambda t: (0.5 + 0.38 * math.sin(2 * math.pi * t / 7.0), 0.5 + 0.34 * math.sin(2 * math.pi * t / 4.6 + 0.6))
    t0 = time.time() + 5
    while True:
        frame, n = cam.latest(n); out = gaze(frame)
        now = time.time(); t = now - t0
        if t > seconds: break
        cv = lap.canvas(14)
        if t < 0:
            lap.text(cv, "Demo: follow the white ring with your eyes.", lap.h // 2 - 30, (235, 235, 235), 1.3, x=lap.w // 2 - 420)
            lap.text(cv, f"starting in {math.ceil(-t)}   (Esc cancels)", lap.h // 2 + 30, (0, 220, 255), 1.0, x=lap.w // 2 - 420)
            tx, ty = path(0)
        else:
            if rec is None and record:
                rec = subprocess.Popen(["screencapture", "-x", "-v", "-V", str(int(seconds)), "-D", "1", record])
                t0 = time.time() + 0.8; t = -0.8  # the recorder takes a moment to start
            tx, ty = path(max(t, 0))
        tx, ty = tx * lap.w, ty * lap.h
        lap.circle(cv, tx, ty, 26, (245, 245, 245), 3); lap.circle(cv, tx, ty, 5, (245, 245, 245))
        if out is not None and out["blink"] < 0.5:
            p = filt(mapper.predict(out["s"])[0], now)
            trail = (trail + [p.copy()])[-14:]
            for i, q in enumerate(trail[:-1]):
                lap.circle(cv, q[0], q[1], 3 + i * 0.5, (0, 40 + 12 * i, 0))
            lap.circle(cv, p[0], p[1], 16, (60, 255, 90))
            if t > 0.5:
                errs.append(math.hypot(p[0] - tx, p[1] - ty) / lap.ppm / 10)
        lap.text(cv, "white ring: where I am looking      green dot: where a webcam thinks I am looking", lap.h - 70, (150, 150, 150), 0.8, x=60)
        if errs:
            lap.text(cv, f"median error {np.median(errs):.1f} cm", lap.h - 34, (150, 150, 150), 0.8, x=60)
        lap.show(cv)
        if poll_key() == "esc": break
    if rec is not None:
        rec.wait()
    print(f"demo: median error {np.median(errs):.1f} cm over {len(errs)} looks" if errs else "demo: no face was seen", flush=True)


def read(name, default):
    p = os.path.join(STATE, name)
    return open(p).read() if os.path.exists(p) else default


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--camera", type=int, default=None, help="OpenCV camera index (default: the built-in camera)")
    ap.add_argument("--units", choices=["ne", "gpu"], default="ne", help="where the models run: the Neural Engine (default) or the GPU")
    ap.add_argument("--recalibrate", action="store_true")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--point", action="store_true")
    ap.add_argument("--frames", type=int, default=3, help="--serve: camera frames read per answer when not tracking")
    ap.add_argument("--track", action="store_true", help="--serve: follow the eyes all the time, so answers are instant")
    ap.add_argument("--glow", action="store_true", help="--serve: a small dot in the corner of the Ghostty or iTerm pane being looked at (implies --track)")
    ap.add_argument("--fps", type=float, default=20, help="--serve --track: looks per second")
    ap.add_argument("--light", action="store_true", help="--bench: time the light path the tracking daemon uses")
    ap.add_argument("--demo", type=float, default=0, metavar="SECONDS", help="a target to follow with your eyes and the gaze dot chasing it")
    ap.add_argument("--record", help="--demo: record the laptop screen to this .mov")
    a = ap.parse_args()
    if a.point:
        import socket
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(3)
        try:
            c.connect(SOCK); c.sendall(b"point\n"); print(c.recv(128).decode().strip())
        except OSError as e:
            print(f"no gaze daemon ({e})")
        return
    cam, gaze = Camera(builtin_camera() if a.camera is None else a.camera), Gaze(a.units, light=a.serve and (a.track or a.glow) or a.light or a.demo > 0)
    if a.serve:
        return serve(cam, gaze, a)

    if a.bench:
        n, ts = 0, []
        for i in range(120):
            frame, n = cam.latest(n); t = time.time(); out = gaze(frame)
            if out is not None: ts.append(time.time() - t)
        ts = 1000 * np.array(ts[5:])
        print(f"{a.units}{' light' if a.light else ''}: median {np.median(ts):.0f} ms/frame, 95th percentile {np.percentile(ts, 95):.0f} ms, worst {ts.max():.0f} ms, "
              f"offset {np.degrees(gaze.offset).round(2)} deg after {gaze.refreshes} refreshes, face in {len(ts) + 5}/120 frames")
        cam.ok = False
        return

    if a.demo:
        lap, _ = open_displays(laptop_only=True)
        if not os.path.exists(os.path.join(STATE, "calib.npz")):
            raise SystemExit("not calibrated: run  gaze  first")
        return demo(cam, gaze, lap, PhysMapper(lap.w, lap.h, lap.ppm).load(os.path.join(STATE, "calib.npz")), a.demo, a.record)
    lap, ext = open_displays()
    cpath, epath = os.path.join(STATE, "calib.npz"), os.path.join(STATE, "calib_ext.npz")
    if os.path.exists(cpath) and not a.recalibrate:
        mapper, rep = PhysMapper(lap.w, lap.h, lap.ppm).load(cpath), read("calib.txt", "laptop: saved calibration")
    else:
        r = calibrate_laptop(cam, gaze, lap, ext)
        if r is None: return
        mapper, rep = r
    plane, erep = None, ""
    if ext is not None:
        if os.path.exists(epath) and not a.recalibrate:
            plane, erep = Plane(ext.w, ext.h, ext.ppm).load(epath), read("calib_ext.txt", "external: saved calibration")
        else:
            r = calibrate_ext(cam, gaze, lap, ext, mapper)
            if r is None: return
            plane, erep = r

    filt, smooth, n, fps, tprev, active = OneEuro(), True, 0, 0, time.time(), lap
    grid = [(x, y) for y in (0.1, 0.5, 0.9) for x in (0.1, 0.5, 0.9)]
    while True:
        frame, n = cam.latest(n); out = gaze(frame)
        now = time.time(); fps = 0.9 * fps + 0.1 / max(now - tprev, 1e-3); tprev = now
        canv = {D: D.canvas(18) for D in (lap, ext) if D is not None}
        for D, cv in canv.items():
            for gx, gy in grid:
                cv2.drawMarker(cv, D.P(gx * D.w, gy * D.h), (90, 90, 90), cv2.MARKER_CROSS, 26, 2)
        inset(lap, canv[lap], frame, out)
        if out is not None and out["blink"] < 0.5:
            cand = {lap: mapper.predict(out["s"])[0]}
            if plane is not None:
                c, g = mapper.rays(out["s"])
                cand[ext] = plane.predict(c, g)[0]
            other = next((D for D in cand if D is not active), None)
            if other is not None and outside_mm(cand[other], other) + 25 < outside_mm(cand[active], active):
                active, filt = other, OneEuro()
            raw = cand[active]
            p = filt(raw, now) if smooth else raw
            p = np.clip(p, [0, 0], [active.w, active.h])
            cv = canv[active]
            active.circle(cv, raw[0], raw[1], 5, (0, 140, 255))
            active.circle(cv, p[0], p[1], 30, (0, 255, 0), 4)
            active.circle(cv, p[0], p[1], 6, (0, 255, 0))
            lap.text(canv[lap], f"looking at: {'LAPTOP' if active is lap else 'EXTERNAL'}  {int(p[0])},{int(p[1])}   face {mapper.distance_cm(out['s']):.0f} cm from laptop screen   {fps:.0f} fps", lap.h - 92)
        else:
            lap.text(canv[lap], "no face / blink", lap.h - 92, (0, 120, 255))
        lap.text(canv[lap], f"{rep}   |   {erep}", lap.h - 60)
        lap.text(canv[lap], f"Esc quit   C recalibrate all   U recalibrate external   F smoothing {'on' if smooth else 'off'}   |   green = smoothed, orange = raw", lap.h - 28)
        for D, cv in canv.items():
            D.show(cv)
        k = poll_key()
        if k == "esc": break
        if k == "f": smooth = not smooth
        if k == "c":
            r = calibrate_laptop(cam, gaze, lap, ext)
            if r is None: break
            mapper, rep = r
        if k in ("c", "u") and ext is not None:
            r = calibrate_ext(cam, gaze, lap, ext, mapper)
            if r is None: break
            plane, erep = r
        if k in ("c", "u"):
            filt = OneEuro()
    cam.ok = False


if __name__ == "__main__":
    main()
