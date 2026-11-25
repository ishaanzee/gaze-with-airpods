"""Build the Core ML models gaze runs on: UniGaze ViT-H/14 and ViT-L/16, fp16 activations, int8 weights.

Run by install.sh in a throwaway environment (coremltools converts with torch 2.7 and numpy 1.x; the
runtime environment has neither torch nor unigaze):

    uv run --no-project --python 3.11 --with torch==2.7.0 --with 'numpy<2' --with coremltools==9.0 --with unigaze convert.py

Measured on an M5 Pro, one face per call (ViT-H / ViT-L):
    Neural Engine   55 ms / 17 ms, every operation on the engine, GPU untouched
    GPU             17 ms / 12 ms when the GPU is free, 2-3x that when something else is using it
    energy          about 0.15 J / 0.04 J on the Neural Engine, the same order on the GPU
int8 per-channel weights halve the files (1.2 GB -> 600 MB for ViT-H), run 15% faster on the Neural
Engine than fp16 weights, and move the output by under 0.04 degrees. A batch of two is slower than two
calls on the Neural Engine, so the models take one face.
"""
import os, shutil, sys, tempfile, time, warnings

warnings.filterwarnings("ignore")
import numpy as np, torch, coremltools as ct, coremltools.optimize.coreml as cto, unigaze

STATE = os.path.expanduser("~/Library/Application Support/gaze")


class Head(torch.nn.Module):
    def __init__(self, model):
        super().__init__(); self.model = model

    def forward(self, x):
        return self.model(x)["pred_gaze"]


def build(name, short):
    dest = os.path.join(STATE, short + ".mlmodelc")
    if os.path.isdir(dest):
        return print(f"{short}: already built", flush=True)
    t0 = time.time()
    net = Head(unigaze.load(name, device="cpu").float().eval()).eval()
    torch.manual_seed(0)
    xs = [torch.randn(1, 3, 224, 224) for _ in range(4)]
    with torch.no_grad():
        want = [net(x).numpy() for x in xs]
    fp16 = ct.convert(torch.jit.trace(net, xs[0], strict=False), inputs=[ct.TensorType(name="x", shape=xs[0].shape)],
                      outputs=[ct.TensorType(name="gaze")], convert_to="mlprogram",
                      compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
    int8 = cto.linear_quantize_weights(fp16, cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_channel")))
    # int8 weights first (half the file, faster on the Neural Engine). Where they move the answer too far
    # (0.5 degrees for ViT-L on an M3 Pro, macOS 27; upstream measured 0.04 on an M5 Pro), fp16 weights.
    for weights, ml in (("int8", int8), ("fp16", fp16)):
        with tempfile.TemporaryDirectory() as tmp:
            pkg = os.path.join(tmp, short + ".mlpackage")
            ml.save(pkg)
            loaded = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.CPU_ONLY)  # its compiled copy lives as long as it does
            shutil.rmtree(dest, ignore_errors=True)
            shutil.copytree(loaded.get_compiled_model_path(), dest)
        model = ct.models.CompiledMLModel(dest, compute_units=ct.ComputeUnit.CPU_ONLY)
        off = max(float(np.degrees(np.abs(model.predict({"x": x.numpy()})["gaze"] - w)).max()) for x, w in zip(xs, want))
        print(f"{short}: {weights} weights built in {time.time() - t0:.0f} s, {off:.3f} degrees from the PyTorch model", flush=True)
        # The inputs are noise, not faces, which is the worst case for fp16 activations: a sanity check that
        # the conversion is not broken, not the accuracy on a face. fp16 weights are the last resort, so
        # they are held to a looser limit.
        if off <= (0.3 if weights == "int8" else 1.0):
            return
        del model
        shutil.rmtree(dest)
    sys.exit(f"{short}: the converted model is {off:.2f} degrees off: not kept")


if __name__ == "__main__":
    os.makedirs(STATE, exist_ok=True)
    for name, short in (("unigaze_h14_joint", "h14"), ("unigaze_l16_joint", "l16")):
        build(name, short)
