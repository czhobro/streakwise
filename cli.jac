import argparse;
import asyncio;
import datetime;
import getpass;
import json;
import os;
import sys;
import urllib.error;
import urllib.request;
import from pathlib { Path }
import from jaclang.server { sv_client }
import from core.planner {
    Dashboard,
    HabitView,
    GoalView,
    join,
    dashboard,
    add_goal,
    remove_goal,
    add_milestone,
    toggle_milestone,
    add_habit,
    remove_habit,
    check_in,
    plan_day
}

glob DAY_NAMES: list[str] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
     COLOR: bool = sys.stdout.isatty() and not os.environ.get("NO_COLOR");

def paint(text: str, code: str) -> str {
    return f"\033[{code}m{text}\033[0m" if COLOR else text;
}

def green(text: str) -> str {
    return paint(text, "32");
}

def dim(text: str) -> str {
    return paint(text, "2");
}

def bold(text: str) -> str {
    return paint(text, "1");
}

def flame(n: int) -> str {
    return paint(f"🔥{n}", "33") if n else "";
}

def auth_request(base: str, username: str, password: str, signup: bool) -> str {
    identity = {"type": "username", "value": username};
    body: dict[str, any] = {"credential": {"type": "password", "password": password}};
    if signup {
        body["identities"] = [identity];
    } else {
        body["identity"] = identity;
    }
    request = urllib.request.Request(
        base + "/user/" + ("register" if signup else "login"),
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}
    );
    try {
        with urllib.request.urlopen(request, timeout=15) as response {
            return str(json.loads(response.read())["data"]["token"]);
        }
    } except urllib.error.HTTPError as e {
        detail = "";
        try {
            payload = json.loads(e.read());
            detail = str(
                payload.get("error", {}).get("message") or payload.get("detail") or ""
            );
        } except Exception {}
        raise ValueError(detail or f"Server answered {e.code}.");
    } except urllib.error.URLError {
        raise ValueError(f"Cannot reach {base}. Is `jac run` running?");
    }
}

def parse_days(text: str) -> list[int] {
    value = text.strip().lower();
    if value in ["", "daily", "every", "all"] {
        return [0, 1, 2, 3, 4, 5, 6];
    }
    if value == "weekdays" {
        return [0, 1, 2, 3, 4];
    }
    if value == "weekends" {
        return [5, 6];
    }
    days: list[int] = [];
    for part in value.replace(" ", "").split(",") {
        if part[:3] not in DAY_NAMES {
            raise ValueError(
                f"Unknown day '{part}'. Use mon,tue,... or daily/weekdays/weekends."
            );
        }
        days.append(DAY_NAMES.index(part[:3]));
    }
    return days;
}

def describe_days(days: list[int]) -> str {
    if len(days) == 7 {
        return "daily";
    }
    if days == [0, 1, 2, 3, 4] {
        return "weekdays";
    }
    return ",".join([DAY_NAMES[d] for d in days]);
}

def pick[T](items: list[T], query: str, title: Callable, what: str) -> T {
    q = query.strip().lower().lstrip("#");
    if q.isdigit() and 1 <= int(q) <= len(items) {
        return items[int(q) - 1];
    }
    exact = [
        i
        for i in items
        if title(i).lower() == q
    ];
    if exact {
        return exact[0];
    }
    partial = [
        i
        for i in items
        if q in title(i).lower()
    ];
    if len(partial) == 1 {
        return partial[0];
    }
    if not partial {
        raise ValueError(f"No {what} matches '{query}'.");
    }
    names = ", ".join([title(i) for i in partial]);
    raise ValueError(f"'{query}' matches several {what}s: {names}. Be more specific.");
}

def history_bar(states: list[str]) -> str {
    marks = {
        "done": green("■"),
        "miss": paint("×", "31"),
        "open": "□",
        "off": dim("·")
    };
    return "".join([marks.get(s, "·") for s in states]);
}

def show_today(board: Dashboard) -> None {
    print(
        bold(f"{board.weekday} {board.today}")
            + f"  ·  {board.done_today}/{board.due_today} habits done"
            + (
                f"  ·  longest streak {flame(board.top_streak)}"
                    if board.top_streak
                    else ""
            )
    );
    due = [
        h
        for h in board.habits
        if h.due_today
    ];
    if not board.habits {
        print(dim("No habits yet. Try: jac run cli -- add-habit \"Read 20 pages\""));
    }
    for (i, h) in enumerate(board.habits) {
        if not h.due_today {
            continue;
        }
        box = green("[x]") if h.done_today else "[ ]";
        goal = dim(f"  → {h.goal}") if h.goal else "";
        print(f"  {i + 1:>2}. {box} {h.title}  {flame(h.streak)}{goal}");
    }
    resting = [
        h.title
        for h in board.habits
        if not h.due_today
    ];
    if resting {
        print(dim("  resting today: " + ", ".join(resting)));
    }
    if board.goals {
        print(bold("\nGoals"));
        for g in board.goals {
            print(f"  {goal_line(g)}");
        }
    }
    if due and all(h.done_today for h in due) {
        print(green("\nAll done for today. Nice work!"));
    }
}

def goal_line(g: GoalView) -> str {
    filled = round(g.progress / 10);
    bar = green("█" * filled) + dim("░" * (10 - filled));
    when = "";
    if g.target {
        when = "  due today"
            if g.days_left == 0
            else ("  overdue" if g.days_left < 0 else f"  {g.days_left}d left");
    }
    step = dim(f"  next: {g.next_step}") if g.next_step else "";
    return f"{bar} {g.progress:>3}%  {g.title}{when}{step}";
}

async def seed_demo(board: Dashboard, day: datetime.date) -> None {
    if board.habits or board.goals {
        raise ValueError(
            "seed-demo only runs on an empty account (this one already has data)."
        );
    }
    iso = lambda (offset: int) -> str { (
        day + datetime.timedelta(days=offset)
    ).isoformat(); };
    week_ago = iso(-7);
    run = await add_goal("Run a 10K", "Feel strong before winter", iso(45), week_ago);
    for (title, done) in [
        ("Run 5K without stopping", True),
        ("Run 8K", False),
        ("Sign up for a race", False)
    ] {
        step = await add_milestone(run, title);
        if done {
            await toggle_milestone(step);
        }
    }
    study = await add_goal("Ace this semester's projects", "", iso(9), week_ago);
    for title in [
        "Outline the project spec",
        "Pass the public tests",
        "Write the README"
    ] {
        await add_milestone(study, title);
    }
    habits = [
        ("Morning run", [0, 2, 4, 6], run, [2, 3, 5, 7]),
        ("Study 1 hour", [0, 1, 2, 3, 4], study, [1, 2, 3, 4, 5, 6, 7]),
        ("Read 20 pages", [0, 1, 2, 3, 4, 5, 6], "", [1, 2, 4, 5, 6, 7]),
        ("Stretch 10 min", [0, 1, 2, 3, 4, 5, 6], "", [1, 2, 3])
    ];
    for (title, days, goal, back) in habits {
        habit = await add_habit(title, days, goal, week_ago);
        for b in back {
            if (day - datetime.timedelta(days=b)).weekday() in days {
                await check_in(habit, iso(-b), day.isoformat());
            }
        }
    }
    print(
        green("✓ Seeded a sample week: 2 goals, 4 habits, and a week of check-ins.\n")
    );
}

async def main -> int {
    parser = argparse.ArgumentParser(
        prog="streakwise",
        description="Streakwise from your terminal: habits, streaks, goals and an AI day plan."
    );
    parser.add_argument(
        "--url", `default=os.environ.get("PLANNER_URL", "http://127.0.0.1:8000")
    );
    sub = parser.add_subparsers(dest="command");
    for name in ["login", "signup"] {
        p = sub.add_parser(name, help=f"{name} and remember the session");
        p.add_argument("username");
    }
    sub.add_parser("logout", help="forget the saved session");
    sub.add_parser("today", help="today's habits and goals (default)");
    sub.add_parser("habits", help="every habit with streaks and 14-day history");
    sub.add_parser("goals", help="goals with milestones");
    sub.add_parser("week", help="4-week heatmap");
    p = sub.add_parser("done", help="check in (or undo) a habit by number or name");
    p.add_argument("habit");
    p.add_argument("--date", `default="", help="YYYY-MM-DD, up to 7 days back");
    p = sub.add_parser("add-habit", help="create a habit");
    p.add_argument("title");
    p.add_argument(
        "--days", `default="daily", help="daily | weekdays | weekends | mon,wed,fri"
    );
    p.add_argument("--goal", `default="", help="goal it supports (name or number)");
    p = sub.add_parser("rm-habit", help="delete a habit and its history");
    p.add_argument("habit");
    p = sub.add_parser("add-goal", help="create a goal");
    p.add_argument("title");
    p.add_argument("--why", `default="");
    p.add_argument("--by", `default="", help="target date YYYY-MM-DD");
    p = sub.add_parser("rm-goal", help="delete a goal and its milestones");
    p.add_argument("goal");
    p = sub.add_parser("step", help="add a milestone to a goal");
    p.add_argument("goal");
    p.add_argument("title");
    p = sub.add_parser("tick", help="toggle a milestone by name");
    p.add_argument("milestone");
    p = sub.add_parser("plan", help="plan the rest of today");
    p.add_argument("note", nargs="?", `default="", help="energy, classes, free time…");
    sub.add_parser("seed-demo", help="fill an empty account with a sample week");
    args = parser.parse_args();
    command = args.command or "today";
    base = str(args.url).rstrip("/");
    session = Path(
        os.environ.get("STREAKWISE_SESSION", str(Path.home() / ".streakwise.json"))
    );
    os.environ["JAC_APP_PLANNER_URL"] = base + "/api/planner";
    today = datetime.date.today().isoformat();
    try {
        if command == "logout" {
            session.unlink(missing_ok=True);
            print("Signed out.");
            return 0;
        }
        if command in ["login", "signup"] {
            password = os.environ.get("PLANNER_PASSWORD")
                or getpass.getpass("Password: ");
            token = auth_request(
                base, args.username.strip(), password, command == "signup"
            );
            sv_client.set_bearer_token(token);
            name = await join(args.username.strip());
            fd = os.open(str(session), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
            with os.fdopen(fd, "w") as handle {
                json.dump({"url": base, "token": token, "username": name}, handle);
            }
            print(green("✓") + f" Signed in as {name}");
            return 0;
        }
        saved = json.loads(session.read_text()) if session.exists() else {};
        if saved.get("url") != base or not saved.get("token") {
            raise ValueError("Not signed in. Run: jac run cli -- login <username>");
        }
        sv_client.set_bearer_token(str(saved["token"]));
        board = await dashboard(today);
        if command == "today" {
            show_today(board);
        } elif command == "habits" {
            if not board.habits {
                print(dim("No habits yet."));
            }
            for (i, h) in enumerate(board.habits) {
                print(
                    f"{i + 1:>2}. {bold(h.title)}  {dim(describe_days(h.days))}  {flame(
                        h.streak
                    )}"
                );
                print(
                    f"    {history_bar(h.history)}  best {h.best} · {h.rate30}% last 30 days"
                        + (f" · {h.goal}" if h.goal else "")
                );
            }
            if board.habits {
                print(
                    dim("    ■ done  × missed  □ today  · rest day   (last 14 days)")
                );
            }
        } elif command == "goals" {
            if not board.goals {
                print(
                    dim(
                        "No goals yet. Try: jac run cli -- add-goal \"Run a 10K\" --by 2026-11-15"
                    )
                );
            }
            for (i, g) in enumerate(board.goals) {
                print(f"{i + 1:>2}. {goal_line(g)}");
                for m in g.milestones {
                    print(f"      {green('☑') if m.done else '☐'} {m.title}");
                }
            }
        } elif command == "week" {
            print(dim("   " + " ".join([d[:2] for d in DAY_NAMES])));
            first = datetime.date.fromisoformat(board.heatmap[0].date);
            row = "   " + "   " * first.weekday();
            for day in board.heatmap {
                on = datetime.date.fromisoformat(day.date);
                if on.weekday() == 0 and row.strip() {
                    print(row);
                    row = "   ";
                }
                ratio = day.done / day.due if day.due else (1 if day.done else -1);
                cell = dim("··")
                    if ratio < 0
                    else (
                        green("██")
                            if ratio >= 1
                            else (
                                paint("▓▓", "32")
                                    if ratio >= 0.5
                                    else (
                                        paint("░░", "32")
                                            if ratio > 0
                                            else paint("░░", "31")
                                    )
                            )
                    );
                row += cell + " ";
            }
            print(row);
            print(dim("   ██ all done  ▓▓ half+  ░░ some/none  ·· nothing due"));
        } elif command == "done" {
            h = pick(
                board.habits,
                args.habit,
                lambda (x: HabitView) -> str { x.title; },
                "habit"
            );
            state = await check_in(h.id, args.date, today);
            after = await dashboard(today);
            streak = [
                x.streak
                for x in after.habits
                if x.id == h.id
            ][0];
            when = args.date or "today";
            print(
                green("✓ Checked in") + f" {h.title} for {when}  {flame(streak)}"
                    if state
                    else f"↺ Undid check-in for {h.title} ({when})"
            );
        } elif command == "add-habit" {
            goal_id = "";
            if args.goal {
                goal_id = pick(
                    board.goals,
                    args.goal,
                    lambda (x: GoalView) -> str { x.title; },
                    "goal"
                ).id;
            }
            days = parse_days(args.days);
            await add_habit(args.title, days, goal_id, today);
            print(green("+ Habit") + f" {args.title} ({describe_days(sorted(days))})");
        } elif command == "rm-habit" {
            h = pick(
                board.habits,
                args.habit,
                lambda (x: HabitView) -> str { x.title; },
                "habit"
            );
            await remove_habit(h.id);
            print(f"Deleted habit {h.title}");
        } elif command == "add-goal" {
            await add_goal(args.title, args.why, args.by, today);
            print(
                green("+ Goal")
                    + f" {args.title}"
                    + (f" by {args.by}" if args.by else "")
            );
        } elif command == "rm-goal" {
            g = pick(
                board.goals, args.goal, lambda (x: GoalView) -> str { x.title; }, "goal"
            );
            await remove_goal(g.id);
            print(f"Deleted goal {g.title}");
        } elif command == "step" {
            g = pick(
                board.goals, args.goal, lambda (x: GoalView) -> str { x.title; }, "goal"
            );
            await add_milestone(g.id, args.title);
            print(green("+ Milestone") + f" {args.title} → {g.title}");
        } elif command == "tick" {
            steps = [m for g in board.goals for m in g.milestones];
            m = pick(
                steps, args.milestone, lambda (x: any) -> str { x.title; }, "milestone"
            );
            done = await toggle_milestone(m.id);
            print((green("☑ Done: ") if done else "☐ Reopened: ") + m.title);
        } elif command == "seed-demo" {
            await seed_demo(board, datetime.date.today());
            show_today(await dashboard(today));
        } elif command == "plan" {
            now = datetime.datetime.now().strftime("%H:%M");
            plan = await plan_day(today, now, args.note);
            print(bold(plan.focus));
            for b in plan.blocks {
                print(f"  {green(b.time)}  {b.title} {dim(f'({b.minutes} min)')}");
                if b.why {
                    print(dim(f"         {b.why}"));
                }
            }
            print(
                dim(
                    "✦ planned by AI"
                        if plan.ai
                        else "rule-based plan (set ANTHROPIC_API_KEY on the server for AI plans)"
                )
            );
        }
        return 0;
    } except Exception as e {
        message = str(e);
        if "401" in message
            or "nauthorized" in message
            or "sign in" in message.lower() {
            message = "Session expired or not signed in. Run: jac run cli -- login <username>";
        }
        print(paint("streakwise: ", "31") + message, file=sys.stderr);
        return 1;
    }
}

with entry:__main__ {
    sys.`exit(asyncio.run(main()));
}
