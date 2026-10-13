"""
Regenerate assets/parity.json for the Flutter parity gate (spec section 6).

WHY THIS EXISTS
---------------
The previously shipped parity.json was unusable: `landmarks` had 12 rows while
`feats`/`logits`/`true` had 30, and the rows were not aligned -- only 2 of the
12 landmark rows reproduced any feature row. Running the spec's own section 4
function in Python against that fixture gave featDiff=2.2, logitDiff=18.5,
agree=9/12. No Dart implementation can pass a gate built on it.

The root cause to avoid: `landmarks`, `feats`, `logits` and `true` MUST be
built in a single pass over the same samples, in the same order. Never
assemble them from separate loops or separate files.

USAGE
-----
Run in the training environment (the one with mediapipe 0.10.14, matching what
produced the model -- version drift here is the prime suspect if parity passes
but live accuracy is poor).

    python tools/export_parity.py \
        --images  /path/to/heldout \
        --model   assets/nsl.tflite \
        --meta    assets/meta.json \
        --out     assets/parity.json \
        --per-class 2

`--images` must be a directory of per-class subfolders named exactly as the
labels in meta.json, e.g. heldout/<label>/*.jpg

Aim for coverage of ALL 36 classes. The old fixture contained only 2 distinct
labels, so even fully repaired it would have exercised 2/36 of the model.
Include the known-weak pairs explicitly: the spec flags ठ/ट (F1 0.69/0.77)
and ञ/ख as landmark-ambiguous and frequently confused.
"""
import argparse, json, sys
from pathlib import Path

import numpy as np

TIPS = [4, 8, 12, 16, 20]
CURLS = [(1, 2, 3), (5, 6, 7), (9, 10, 11), (13, 14, 15), (17, 18, 19)]


def feats(lm):
    """EXACT copy of the training-time function. Do not 'improve' this."""
    lm = np.asarray(lm, np.float32).copy()
    lm -= lm[0]
    s = np.linalg.norm(lm[9] - lm[0])
    if s < 1e-6:
        return None
    lm /= s
    out = [lm.reshape(-1)]
    for i in range(5):
        for j in range(i + 1, 5):
            out.append([np.linalg.norm(lm[TIPS[i]] - lm[TIPS[j]])])
    for a, b, c in CURLS:
        v1, v2 = lm[b] - lm[a], lm[c] - lm[b]
        cs = v1 @ v2 / (np.linalg.norm(v1) * np.linalg.norm(v2) + 1e-8)
        out.append([np.arccos(np.clip(cs, -1, 1))])
    return np.concatenate(out).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True)
    ap.add_argument("--model", default="assets/nsl.tflite")
    ap.add_argument("--meta", default="assets/meta.json")
    ap.add_argument("--out", default="assets/parity.json")
    ap.add_argument("--per-class", type=int, default=2)
    args = ap.parse_args()

    import cv2, mediapipe as mp, tensorflow as tf

    meta = json.load(open(args.meta, encoding="utf-8"))
    labels, mu, sd = meta["labels"], np.array(meta["mu"], np.float32), np.array(meta["sd"], np.float32)
    det_conf = float(meta.get("det_conf", 0.30))

    print(f"mediapipe {mp.__version__}  (training used 0.10.14)")
    if mp.__version__ != "0.10.14":
        print("  WARNING: version drift. Landmarks may differ from training.", file=sys.stderr)

    it = tf.lite.Interpreter(model_path=args.model)
    it.allocate_tensors()
    ind, outd = it.get_input_details()[0], it.get_output_details()[0]

    hands = mp.solutions.hands.Hands(
        static_image_mode=True, max_num_hands=1, min_detection_confidence=det_conf
    )

    # SINGLE PASS -- every array appended together, so rows cannot desynchronise.
    out = {"landmarks": [], "feats": [], "logits": [], "true": []}
    missing = []

    for label in labels:
        d = Path(args.images) / label
        if not d.is_dir():
            missing.append(label)
            continue
        taken = 0
        for img_path in sorted(d.iterdir()):
            if taken >= args.per_class:
                break
            img = cv2.imread(str(img_path))
            if img is None:
                continue
            res = hands.process(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
            if not res.multi_hand_landmarks:
                continue
            lm = [[p.x, p.y, p.z] for p in res.multi_hand_landmarks[0].landmark]
            f = feats(lm)
            if f is None:
                continue
            std = ((f - mu) / sd).astype(np.float32)[None, :]
            it.set_tensor(ind["index"], std)
            it.invoke()
            lg = it.get_tensor(outd["index"])[0]

            out["landmarks"].append([[float(v) for v in p] for p in lm])
            out["feats"].append([float(v) for v in f])
            out["logits"].append([float(v) for v in lg])
            out["true"].append(label)
            taken += 1
        if taken == 0:
            missing.append(label)

    n = len(out["landmarks"])
    assert n == len(out["feats"]) == len(out["logits"]) == len(out["true"]), \
        "row desynchronisation -- this is the bug that broke the last fixture"

    # Self-check: the gate must pass in Python before it can pass in Dart.
    agree = sum(int(np.argmax(out["logits"][i]) == labels.index(out["true"][i])) for i in range(n))
    print(f"\nwrote {n} fixtures covering {len(set(out['true']))}/{len(labels)} classes")
    print(f"python self-check: argmax == true label on {agree}/{n} "
          f"({100*agree/n:.1f}%)  -- expect ~94%, this is model accuracy not a parity failure")
    if missing:
        print(f"NO SAMPLES for {len(missing)} classes: {' '.join(missing)}", file=sys.stderr)

    json.dump(out, open(args.out, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"-> {args.out}")


if __name__ == "__main__":
    main()
