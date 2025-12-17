#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "rich>=13.0",
#     "pyyaml>=6.0",
# ]
# ///
"""
System Design Atlas - Generation Monitor
Live action progress monitor with spinners and streaming logs.
"""

import os
import re
import time
import subprocess
from pathlib import Path
from datetime import datetime
from collections import defaultdict

import yaml
from rich.console import Console, Group
from rich.table import Table
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, BarColumn, TextColumn, TimeElapsedColumn
from rich.live import Live
from rich.layout import Layout
from rich.text import Text
from rich import box
from rich.style import Style

SCRIPT_DIR = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent
SOLUTIONS_DIR = PROJECT_DIR / "solutions"
LOGS_DIR = PROJECT_DIR / "logs"
DRAFTS_DIR = PROJECT_DIR / "drafts"
REVIEWED_DIR = PROJECT_DIR / "reviewed"
PROBLEMS_FILE = PROJECT_DIR / "problems.yaml"

console = Console()

SPINNERS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
STEP_EMOJI = {
    "generate": "📝",
    "review": "🔍",
    "simplify": "✂️",
    "validate": "✅",
    "done": "🎉",
    "error": "💥",
}

def load_problems():
    with open(PROBLEMS_FILE) as f:
        data = yaml.safe_load(f)
    return data.get("problems", [])

def get_completed_solutions():
    completed = set()
    for md_file in SOLUTIONS_DIR.rglob("*.md"):
        completed.add(md_file.stem)
    return completed

def get_job_status(slug):
    """Determine what step a job is on by checking files and logs."""
    solution_file = None
    for cat_dir in SOLUTIONS_DIR.iterdir():
        if cat_dir.is_dir():
            f = cat_dir / f"{slug}.md"
            if f.exists():
                solution_file = f
                break

    draft_file = DRAFTS_DIR / f"{slug}.md"
    reviewed_file = REVIEWED_DIR / f"{slug}.md"
    log_file = LOGS_DIR / f"{slug}.log"

    if solution_file and solution_file.exists():
        return "done", "Complete"

    if not log_file.exists():
        return "waiting", "Queued"

    # Read log to determine current step
    try:
        with open(log_file, 'r') as f:
            content = f.read()

        if "Pass 4/4" in content:
            if "All Mermaid diagrams valid" in content or "diagrams fixed" in content:
                return "done", "Complete"
            return "validate", "Validating Mermaid..."
        elif "Pass 3/4" in content:
            if reviewed_file.exists():
                return "simplify", "Simplifying..."
            return "review", "Reviewing..."
        elif "Pass 2/4" in content:
            return "review", "Reviewing..."
        elif "Pass 1/4" in content:
            return "generate", "Generating..."
        elif "Error" in content or "error" in content.lower()[-500:]:
            return "error", "Error!"
        else:
            return "generate", "Starting..."
    except:
        return "waiting", "..."

def get_active_jobs_with_details():
    """Get active jobs with their current step and elapsed time."""
    jobs = []

    if not LOGS_DIR.exists():
        return jobs

    # Skip meta logs
    SKIP_LOGS = {"batch-run", "frontend-agent", "resimplify-task", "resimplify-url", "resimplify-lock", "resimplify-rate"}

    # Find logs modified in the last 5 minutes (active)
    now = time.time()
    for log_file in LOGS_DIR.glob("*.log"):
        slug = log_file.stem
        if slug in SKIP_LOGS:
            continue

        mtime = log_file.stat().st_mtime
        age = now - mtime

        if age < 300:  # Modified in last 5 minutes
            status, desc = get_job_status(slug)

            # Get start time from first log line
            try:
                ctime = log_file.stat().st_ctime
                elapsed = int(now - ctime)
                elapsed_str = f"{elapsed // 60}:{elapsed % 60:02d}"
            except:
                elapsed_str = "??:??"

            # Get last log line for extra context
            try:
                with open(log_file, 'rb') as f:
                    f.seek(0, 2)
                    size = f.tell()
                    f.seek(max(0, size - 200))
                    last_chunk = f.read().decode('utf-8', errors='ignore')
                    lines = [l.strip() for l in last_chunk.split('\n') if l.strip()]
                    last_line = lines[-1][:50] if lines else ""
            except:
                last_line = ""

            jobs.append({
                "slug": slug,
                "status": status,
                "desc": desc,
                "elapsed": elapsed_str,
                "last_line": last_line,
                "age": age
            })

    # Sort by most recently active
    jobs.sort(key=lambda x: x["age"])
    return jobs[:12]

def get_recent_completions(n=6):
    """Get recently completed solutions."""
    completed = []
    for cat_dir in SOLUTIONS_DIR.iterdir():
        if cat_dir.is_dir():
            for f in cat_dir.glob("*.md"):
                completed.append({
                    "slug": f.stem,
                    "time": f.stat().st_mtime,
                    "category": cat_dir.name
                })

    completed.sort(key=lambda x: x["time"], reverse=True)
    return completed[:n]

def get_streaming_logs(n_lines=12):
    """Get recent log lines from all active jobs for streaming view."""
    log_lines = []
    now = time.time()

    if not LOGS_DIR.exists():
        return log_lines

    for log_file in LOGS_DIR.glob("*.log"):
        # Only look at recently modified logs
        mtime = log_file.stat().st_mtime
        if now - mtime > 300:  # Skip logs older than 5 min
            continue

        slug = log_file.stem
        if slug in ("batch-run", "frontend-agent"):  # Skip meta logs
            continue

        try:
            with open(log_file, 'rb') as f:
                f.seek(0, 2)
                size = f.tell()
                # Read last 2KB
                f.seek(max(0, size - 2048))
                chunk = f.read().decode('utf-8', errors='ignore')

            lines = chunk.split('\n')
            for line in lines[-8:]:  # Last few lines per file
                line = line.strip()
                if line and len(line) > 3:
                    # Skip noisy lines
                    if any(skip in line.lower() for skip in ['───', '===', '---', 'warning:', 'debug:']):
                        continue
                    # Add timestamp from file mtime for sorting
                    log_lines.append({
                        "slug": slug,
                        "line": line[:80],  # Truncate long lines
                        "time": mtime
                    })
        except:
            pass

    # Sort by time and return most recent
    log_lines.sort(key=lambda x: x["time"], reverse=True)

    # Dedupe consecutive identical lines
    seen = set()
    unique = []
    for item in log_lines:
        key = f"{item['slug']}:{item['line']}"
        if key not in seen:
            seen.add(key)
            unique.append(item)

    return unique[:n_lines]

def create_dashboard(problems, completed, active_jobs, tick):
    """Create the live dashboard."""
    total = len(problems)
    done = len(completed)
    remaining = total - done
    active = len([j for j in active_jobs if j["status"] not in ("done", "waiting")])

    # Spinner
    spinner = SPINNERS[tick % len(SPINNERS)]

    # Header with live spinner
    if active > 0:
        status_text = f"[bold green]{spinner}[/] [cyan]{active} workers active[/]"
    else:
        status_text = "[yellow]Waiting for jobs...[/]"

    # Progress bar with animation
    pct = (done / total * 100) if total > 0 else 0
    bar_width = 50
    filled = int(bar_width * done / total) if total > 0 else 0

    # Animated progress bar
    bar_chars = ""
    for i in range(bar_width):
        if i < filled:
            bar_chars += "█"
        elif i == filled and active > 0:
            bar_chars += SPINNERS[(tick + i) % len(SPINNERS)]
        else:
            bar_chars += "░"

    header = Panel(
        Text.from_markup(
            f"[bold cyan]⚡ System Design Atlas[/] - Live Generation Monitor\n"
            f"{status_text}   [dim]Press Ctrl+C to exit[/]"
        ),
        box=box.DOUBLE
    )

    progress_panel = Panel(
        Text.from_markup(
            f"[green]{bar_chars}[/]\n\n"
            f"[bold white]{done:3d}[/] [dim]of[/] [bold]{total}[/] complete   "
            f"[green]({pct:5.1f}%)[/]   "
            f"[yellow]{remaining:3d} remaining[/]   "
            f"[cyan]{active} active[/]"
        ),
        title="[bold]Progress[/]",
        box=box.ROUNDED
    )

    # Active jobs with live spinners
    if active_jobs:
        jobs_lines = []
        for job in active_jobs:
            status = job["status"]
            emoji = STEP_EMOJI.get(status, "⏳")

            if status in ("generate", "review", "simplify", "validate"):
                # Show spinner for active jobs
                spin = SPINNERS[(tick + hash(job["slug"])) % len(SPINNERS)]
                status_str = f"[cyan]{spin}[/] {emoji} [yellow]{job['desc']:<18}[/]"
            elif status == "done":
                status_str = f"   {emoji} [green]{'Done':<18}[/]"
            elif status == "error":
                status_str = f"   {emoji} [red]{'Error':<18}[/]"
            else:
                status_str = f"   ⏳ [dim]{job['desc']:<18}[/]"

            name = job["slug"][:28]
            elapsed = job["elapsed"]

            jobs_lines.append(f"{status_str} [white]{name:<28}[/] [dim]{elapsed}[/]")

        jobs_text = "\n".join(jobs_lines)
    else:
        jobs_text = f"[dim]{spinner} Scanning for active jobs...[/]"

    active_panel = Panel(
        Text.from_markup(jobs_text),
        title=f"[bold]Active Jobs ({active})[/]",
        box=box.ROUNDED
    )

    # Category progress
    by_category = defaultdict(lambda: {"total": 0, "done": 0})
    for p in problems:
        cat = p.get("category_dir", "unknown")
        by_category[cat]["total"] += 1
        if p.get("slug") in completed:
            by_category[cat]["done"] += 1

    cat_lines = []
    for cat, stats in sorted(by_category.items()):
        d, t = stats["done"], stats["total"]
        pct = d / t if t > 0 else 0
        bar_w = 12
        filled = int(bar_w * pct)
        mini_bar = f"[green]{'█' * filled}[/][dim]{'░' * (bar_w - filled)}[/]"

        if d == t:
            check = "[green]✓[/]"
        elif d > 0:
            check = "[yellow]○[/]"
        else:
            check = "[dim]○[/]"

        cat_name = cat.split("-", 1)[-1][:18] if "-" in cat else cat[:18]
        cat_lines.append(f"{check} {mini_bar} [dim]{d:2d}/{t:2d}[/] {cat_name}")

    categories_text = "\n".join(cat_lines)

    cat_panel = Panel(
        Text.from_markup(categories_text),
        title="[bold]Categories[/]",
        box=box.ROUNDED
    )

    # Recent completions
    recent = get_recent_completions(4)
    if recent:
        recent_lines = []
        for r in recent:
            t = datetime.fromtimestamp(r["time"]).strftime("%H:%M:%S")
            recent_lines.append(f"[green]✓[/] [dim]{t}[/] {r['slug'][:30]}")
        recent_text = "\n".join(recent_lines)
    else:
        recent_text = f"[dim]{spinner} Waiting for completions...[/]"

    recent_panel = Panel(
        Text.from_markup(recent_text),
        title="[bold]Recent Completions[/]",
        box=box.ROUNDED
    )

    # Streaming logs
    stream_logs = get_streaming_logs(10)
    if stream_logs:
        stream_lines = []
        for log in stream_logs:
            slug_short = log["slug"][:12].ljust(12)
            line = log["line"]
            # Color code by content
            if "pass" in line.lower() or "saved" in line.lower():
                stream_lines.append(f"[dim]{slug_short}[/] [green]{line}[/]")
            elif "error" in line.lower() or "fail" in line.lower():
                stream_lines.append(f"[dim]{slug_short}[/] [red]{line}[/]")
            elif "generating" in line.lower() or "reviewing" in line.lower() or "simplif" in line.lower():
                stream_lines.append(f"[dim]{slug_short}[/] [cyan]{line}[/]")
            else:
                stream_lines.append(f"[dim]{slug_short}[/] {line}")
        stream_text = "\n".join(stream_lines)
    else:
        stream_text = f"[dim]{spinner} Waiting for log output...[/]"

    stream_panel = Panel(
        Text.from_markup(stream_text),
        title=f"[bold]Live Logs {spinner}[/]",
        box=box.ROUNDED
    )

    # Compose layout
    layout = Layout()
    layout.split_column(
        Layout(header, size=4),
        Layout(progress_panel, size=5),
        Layout(name="middle"),
        Layout(name="bottom")
    )
    layout["middle"].split_row(
        Layout(active_panel, ratio=3),
        Layout(cat_panel, ratio=2)
    )
    layout["bottom"].split_row(
        Layout(stream_panel, ratio=3),
        Layout(recent_panel, ratio=1)
    )

    return layout

def main():
    console.clear()
    problems = load_problems()
    tick = 0

    with Live(console=console, refresh_per_second=4, screen=True) as live:
        try:
            while True:
                completed = get_completed_solutions()
                active_jobs = get_active_jobs_with_details()

                dashboard = create_dashboard(problems, completed, active_jobs, tick)
                live.update(dashboard)

                tick += 1

                # Check if all done
                if len(completed) >= len(problems):
                    active = [j for j in active_jobs if j["status"] not in ("done", "waiting")]
                    if not active:
                        time.sleep(2)
                        break

                time.sleep(0.25)
        except KeyboardInterrupt:
            pass

    console.print("\n[bold green]✨ Monitoring complete![/]")
    final_completed = len(get_completed_solutions())
    console.print(f"[bold]{final_completed}[/] / {len(problems)} solutions generated")

if __name__ == "__main__":
    main()
