#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path
from datetime import datetime, timezone


DATASET_ALIASES = {
    "swe-bench-pro": "ScaleAI/SWE-bench_Pro",
    "swe_bench_pro": "ScaleAI/SWE-bench_Pro",
    "ScaleAI/SWE-bench_Pro": "ScaleAI/SWE-bench_Pro",
    "mmlu-pro": "TIGER-Lab/MMLU-Pro",
    "mmlu_pro": "TIGER-Lab/MMLU-Pro",
    "TIGER-Lab/MMLU-Pro": "TIGER-Lab/MMLU-Pro",
    "humaneval-plus": "evalplus/humanevalplus",
    "humaneval_plus": "evalplus/humanevalplus",
    "evalplus/humanevalplus": "evalplus/humanevalplus",
    "mbpp-plus": "evalplus/mbppplus",
    "mbpp_plus": "evalplus/mbppplus",
    "evalplus/mbppplus": "evalplus/mbppplus",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Download public Ghost grounding datasets without Docker.")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--output-dir")
    parser.add_argument("--mode", choices=["public", "public-only"], default="public")
    parser.add_argument("--limit-rows", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    dataset = DATASET_ALIASES.get(args.dataset, args.dataset)
    out_dir = Path(args.output_dir) if args.output_dir else default_output_dir(dataset)
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "dataset": dataset,
        "requestedDataset": args.dataset,
        "mode": args.mode,
        "dockerUsed": False,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "status": "planned",
        "files": [],
    }

    if args.dry_run:
        manifest["status"] = "dry_run"
        write_manifest(out_dir, manifest)
        return 0

    try:
        from datasets import load_dataset
    except Exception as exc:
        manifest["status"] = "missing_python_dependency"
        manifest["error"] = f"install datasets to download: {exc}"
        write_manifest(out_dir, manifest)
        return 3

    try:
        stream = load_dataset(dataset, split="test", streaming=True)
    except Exception:
        stream = load_dataset(dataset, split="train", streaming=True)

    rows_path = out_dir / "rows.jsonl"
    count = 0
    with rows_path.open("w", encoding="utf-8") as handle:
        for row in stream:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")
            count += 1
            if args.limit_rows and count >= args.limit_rows:
                break

    manifest["status"] = "downloaded_streaming_rows"
    manifest["files"].append({"path": str(rows_path), "rows": count})
    write_manifest(out_dir, manifest)
    return 0


def write_manifest(out_dir: Path, manifest: dict) -> None:
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def default_output_dir(dataset: str) -> Path:
    slug = re.sub(r"[^A-Za-z0-9]+", "_", dataset.split("/")[-1]).strip("_").lower()
    return Path(".ghost") / "knowledge" / slug


if __name__ == "__main__":
    raise SystemExit(main())
