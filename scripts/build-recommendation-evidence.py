#!/usr/bin/env python3
"""Build offline recommendation facts from reviewed scores and pinned GGUF headers.

No scores are inferred from parameter counts. Missing evidence stays missing.
Run update-catalog.py first to populate .test-data/catalog-metadata when needed.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
catalog = json.loads((ROOT / "Sources/HearthCore/catalog.json").read_text())
review = json.loads((ROOT / "scripts/recommendation-evidence.json").read_text())
PUBLISHED_ACTIVE_PARAMETERS = {
    "qwen35-35b-a3": 3.0, "qwen3-instruct-30b-a3": 3.3, "qwen3-coder-30b": 3.3,
    "gemma4-26b-a4b": 3.8, "gpt-oss-20b": 3.6, "gpt-oss-120b": 5.1,
    "lfm25-8b-a1b": 1.5, "deepseek-coder-v2": 2.4,
}
records = []
for model in catalog:
    header = json.loads((ROOT / f".test-data/catalog-metadata/{model['sha256']}.header.json").read_text())
    arch = header["general.architecture"]
    metrics = review["metricsByModel"].get(model["id"], [])
    maximum = int(header.get(arch + ".context_length", model["contextTokens"]))
    # Publisher-stated active parameters (billions), from each bundled MODEL_CARD.md.
    # Routed-expert ratios alone omit shared attention/expert weights and understate this.
    # Used only to estimate relative work in the near-quality resource tie-break,
    # never to extrapolate a tokens/second promise.
    active_parameters = PUBLISHED_ACTIVE_PARAMETERS.get(model["id"])
    # Pinned llama.cpp Metal Q8 attention path. MLA and unreviewed hybrids stay FP16.
    # Dimension alignment is necessary; representative runtime probes supplement this
    # compatibility review. This does not establish quality for every configuration.
    quantized_architectures = {"llama", "qwen2", "qwen3", "qwen3moe", "qwen35", "qwen35moe",
                              "gemma3", "gemma4", "granite", "mistral3", "olmo2", "phi3", "smollm3", "gpt-oss"}
    heads = header.get(arch + ".attention.head_count", 0)
    embedding = header.get(arch + ".embedding_length", 0)
    default_dimension = embedding // heads if isinstance(heads, int) and heads else 0
    dimensions = [header.get(arch + ".attention." + key, default_dimension)
                  for key in ["key_length", "value_length"]]
    dimensions += [v for k, v in header.items() if k in {arch + ".attention.key_length_swa", arch + ".attention.value_length_swa"}]
    quantized_compatible = arch in quantized_architectures and all(isinstance(v, int) and v > 0 and v % 32 == 0 for v in dimensions)
    geometry = None
    layers = header.get(arch + ".block_count", 0)
    kv_heads = header.get(arch + ".attention.head_count_kv", 0)
    if arch in {"qwen35", "qwen35moe"} and isinstance(kv_heads, int) and layers > 0:
        interval = header.get(arch + ".full_attention_interval", 4)
        recurrent = header.get(arch + ".attention.recurrent_layers")
        if not isinstance(recurrent, list):
            recurrent = [(i + 1) % interval != 0 for i in range(layers)]
        full_layers = sum(not x for x in recurrent)
        state = header[arch + ".ssm.state_size"]
        inner = header[arch + ".ssm.inner_size"]
        groups = header[arch + ".ssm.group_count"]
        conv = header[arch + ".ssm.conv_kernel"]
        geometry = {
            "fullAttentionBytesPerToken": full_layers * kv_heads * sum(dimensions[:2]) * 2,
            "slidingAttentionBytesPerToken": 0, "slidingWindowTokens": 0,
            "recurrentStateBytes": sum(recurrent) * 4 * (state * inner + (conv - 1) * (inner + 2 * groups * state)),
            "description": f"{full_layers} full-attention layers plus {sum(recurrent)} recurrent layers; recurrent state stays FP32. Includes room for two partial-state checkpoints."
        }
    elif arch == "gemma4" and isinstance(kv_heads, int) and layers > 0:
        shared = header.get(arch + ".attention.shared_kv_layers", 0)
        pattern = header.get(arch + ".attention.sliding_window_pattern")
        if isinstance(pattern, list) and len(pattern) == layers and 0 <= shared <= layers - 2:
            retained = pattern[:layers - shared]
            sliding = sum(retained)
            full_layers = len(retained) - sliding
            sliding_dimensions = header[arch + ".attention.key_length_swa"] + header[arch + ".attention.value_length_swa"]
            geometry = {
                "fullAttentionBytesPerToken": full_layers * kv_heads * sum(dimensions[:2]) * 2,
                "slidingAttentionBytesPerToken": sliding * kv_heads * sliding_dimensions * 2,
                "slidingWindowTokens": header[arch + ".attention.sliding_window"], "recurrentStateBytes": 0,
                "description": f"{full_layers} full-attention and {sliding} sliding-window cache layers; {shared} later layers share existing cache. Includes a 512-token microbatch and two partial-state checkpoints."
            }
    records.append({
        "modelID": model["id"], "modelSHA256": model["sha256"],
        "maximumContext": maximum,
        "supportsThinking": bool(model.get("reasoning") or any(m["thinking"] for m in metrics)),
        "activeParameters": active_parameters, "metrics": metrics,
        "quantizedCacheCompatible": quantized_compatible,
        "cacheGeometry": geometry,
        "note": "Published results describe upstream models, not this exact compressed file. Evaluation settings differ; ranking is a starting estimate, not a universal intelligence score. Local checks measure this configuration's usability, not its full knowledge or writing quality." if metrics else "No sufficiently comparable evaluation set has been reviewed for this exact model version. Missing evidence does not imply poor quality. This model remains available to download and compare."
    })
destination = ROOT / "Sources/HearthCore/recommendation-evidence.json"
destination.write_text(json.dumps({"checkedAt": review["checkedAt"], "models": records}, indent=2) + "\n")
print(f"Built facts for {len(records)} configurations; {sum(len(r['metrics']) >= 2 for r in records)} have multiple benchmark dimensions.")
