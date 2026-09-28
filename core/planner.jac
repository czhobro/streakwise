import datetime;
import from jaclang.runtime.runtime { JacRuntime }
import from core.coach { DayPlan, HabitBrief, GoalBrief, _plan_for, _ai_available }

glob WEEKDAYS: list[str] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
glob AI_PLANS_PER_DAY: int = 20;

node Profile {
    has username: str,
        ai_day: str = "",
        ai_used: int = 0;
}

node Goal {
    has title: str,
        why: str = "",
        target: str = "",
        created: str = "";
}

node Milestone {
    has title: str,
        done: bool = False;
}

node Habit {
    has title: str,
        days: list[int] = [0, 1, 2, 3, 4, 5, 6],
        created: str = "";
}

node CheckIn {
    has date: str;
}

edge Supports: Goal --> Habit {}

obj MilestoneView {
    has id: str,
        title: str,
        done: bool = False;
}

obj GoalView {
    has id: str,
        title: str,
        why: str = "",
        target: str = "",
        days_left: int = -1,
        progress: int = 0,
        next_step: str = "",
        milestones: list[MilestoneView] = [],
        habits: list[str] = [];
}

obj HabitView {
    has id: str,
        title: str,
        days: list[int] = [],
        goal_id: str = "",
        goal: str = "",
        due_today: bool = True,
        done_today: bool = False,
        streak: int = 0,
        best: int = 0,
        rate30: int = 0,
        history: list[str] = [];
}

obj HeatDay {
    has date: str,
        done: int = 0,
        due: int = 0;
}

obj Dashboard {
    has today: str = "",
        weekday: str = "",
        viewer: str = "",
        habits: list[HabitView] = [],
        goals: list[GoalView] = [],
        heatmap: list[HeatDay] = [],
        due_today: int = 0,
        done_today: int = 0,
        top_streak: int = 0;
}

def _signed_in -> None {
    # :pub endpoints are callable anonymously; those callers land on the shared guest root.
    if jid(root) == jid(root.shared) {
        raise ValueError("Please sign in first.");
    }
}

def _parse_day(value: str) -> datetime.date {
    try {
        return datetime.date.fromisoformat(value.strip());
    } except Exception {
        raise ValueError("Dates must look like YYYY-MM-DD.");
    }
}

def _day_or_today(value: str) -> datetime.date {
    return _parse_day(value) if value.strip() else datetime.date.today();
}

def _clean(text: str, limit: int, what: str) -> str {
    value = text.strip();
    if not value or len(value) > limit {
        raise ValueError(f"{what} must be between 1 and {limit} characters.");
    }
    return value;
}

def _find_goal(goal_id: str) -> Goal {
    for g in [root-->[?:Goal]] {
        if jid(g) == goal_id {
            return g;
        }
    }
    raise ValueError("That goal no longer exists.");
}

def _find_habit(habit_id: str) -> Habit {
    for h in [root-->[?:Habit]] {
        if jid(h) == habit_id {
            return h;
        }
    }
    raise ValueError("That habit no longer exists.");
}

def _habit_view(h: Habit, today: datetime.date) -> HabitView {
    one = datetime.timedelta(days=1);
    done = {c.date for c in [h-->[?:CheckIn]]};
    start = _parse_day(h.created) if h.created else today;
    for d in done {
        start = min(start, _parse_day(d));
    }
    start = min(start, today);
    scheduled = lambda (d: datetime.date) -> bool { d.weekday() in h.days; };
    hit = lambda (d: datetime.date) -> bool { d.isoformat() in done; };

    # Current streak: today's still-open slot does not break it.
    d = today if hit(today) or not scheduled(today) else today - one;
    streak = 0;
    while d >= start {
        if scheduled(d) {
            if not hit(d) {
                break;
            }
            streak += 1;
        }
        d -= one;
    }

    best = 0;
    run = 0;
    d = start;
    while d <= today {
        if scheduled(d) and hit(d) {
            run += 1;
            best = max(best, run);
        } elif scheduled(d) and d < today {
            run = 0;
        }
        d += one;
    }

    due = 0;
    hits = 0;
    d = max(start, today - datetime.timedelta(days=29));
    while d <= today {
        if scheduled(d) and (d < today or hit(d)) {
            due += 1;
            hits += 1 if hit(d) else 0;
        }
        d += one;
    }

    history: list[str] = [];
    for back in range(13, -1, -1) {
        d = today - datetime.timedelta(days=back);
        if hit(d) {
            history.append("done");
        } elif d < start or not scheduled(d) {
            history.append("off");
        } elif d == today {
            history.append("open");
        } else {
            history.append("miss");
        }
    }

    goals = [h<-:Supports:<-];
    return HabitView(
        id=jid(h),
        title=h.title,
        days=h.days,
        goal_id=jid(goals[0]) if goals else "",
        goal=goals[0].title if goals else "",
        due_today=scheduled(today),
        done_today=hit(today),
        streak=streak,
        best=best,
        rate30=round(100 * hits / due) if due else 0,
        history=history
    );
}

def _goal_view(g: Goal, today: datetime.date) -> GoalView {
    steps = [g-->[?:Milestone]];
    finished = len(
        [
            m
            for m in steps
            if m.done
        ]
    );
    open_steps = [
        m.title
        for m in steps
        if not m.done
    ];
    return GoalView(
        id=jid(g),
        title=g.title,
        why=g.why,
        target=g.target,
        days_left=(_parse_day(g.target) - today).days if g.target else -1,
        progress=round(100 * finished / len(steps)) if steps else 0,
        next_step=open_steps[0] if open_steps else "",
        milestones=[
            MilestoneView(id=jid(m), title=m.title, done=m.done) for m in steps
        ],
        habits=[h.title for h in [g->:Supports:->]]
    );
}

def:pub join(username: str) -> str {
    _signed_in();
    manager = JacRuntime.get_user_manager(JacRuntime.get_base_path_dir() or ".");
    user = manager.find_user_by_identity(username.strip());
    if not user or manager.get_root_id(str(user["user_id"])) != jid(root) {
        raise ValueError("This username does not belong to your signed-in account.");
    }
    name = manager.get_username(str(user["user_id"])) or username.strip();
    profiles = [root-->[?:Profile]];
    if not profiles {
        root ++> Profile(username=name);
    } else {
        profiles[0].username = name;
    }
    return name;
}

def:pub dashboard(today: str = "") -> Dashboard {
    _signed_in();
    day = _day_or_today(today);
    profiles = [root-->[?:Profile]];
    habits = [_habit_view(h, day) for h in [root-->[?:Habit]]];
    habits.sort(
        key=lambda (v: HabitView) { (not v.due_today, v.done_today, -v.streak); }
    );
    goals = [_goal_view(g, day) for g in [root-->[?:Goal]]];
    goals.sort(
        key=lambda (v: GoalView) { (v.progress >= 100, v.days_left < 0, v.days_left); }
    );

    heatmap: list[HeatDay] = [];
    all_habits = [root-->[?:Habit]];
    stamps = {jid(h): {c.date for c in [h-->[?:CheckIn]]} for h in all_habits};
    # A habit counts from its creation or its earliest (backfilled) check-in.
    starts = {
        jid(h): min([h.created or day.isoformat()] + list(stamps[jid(h)]))
        for h in all_habits
    };
    for back in range(27, -1, -1) {
        d = day - datetime.timedelta(days=back);
        iso = d.isoformat();
        due = [
            h
            for h in all_habits
            if d.weekday() in h.days and starts[jid(h)] <= iso
        ];
        heatmap.append(
            HeatDay(
                date=iso,
                due=len(due),
                done=len(
                    [
                        h
                        for h in due
                        if iso in stamps[jid(h)]
                    ]
                )
            )
        );
    }

    due_now = [
        v
        for v in habits
        if v.due_today
    ];
    return Dashboard(
        today=day.isoformat(),
        weekday=WEEKDAYS[day.weekday()],
        viewer=profiles[0].username if profiles else "",
        habits=habits,
        goals=goals,
        heatmap=heatmap,
        due_today=len(due_now),
        done_today=len(
            [
                v
                for v in due_now
                if v.done_today
            ]
        ),
        top_streak=max([0] + [v.streak for v in habits])
    );
}

def:pub add_goal(title: str, why: str = "", target: str = "", today: str = "") -> str {
    _signed_in();
    if target.strip() {
        _parse_day(target);
    }
    goal = root ++> Goal(
        title=_clean(title, 80, "A goal title"),
        why=why.strip()[:200],
        target=target.strip(),
        created=_day_or_today(today).isoformat()
    );
    return jid(goal);
}

def:pub remove_goal(goal_id: str) -> bool {
    _signed_in();
    goal = _find_goal(goal_id);
    for m in [goal-->[?:Milestone]] {
        del m;
    }
    del goal;
    return True;
}

def:pub add_milestone(goal_id: str, title: str) -> str {
    _signed_in();
    goal = _find_goal(goal_id);
    step = goal ++> Milestone(title=_clean(title, 120, "A milestone"));
    return jid(step);
}

def:pub toggle_milestone(milestone_id: str) -> bool {
    _signed_in();
    for g in [root-->[?:Goal]] {
        for m in [g-->[?:Milestone]] {
            if jid(m) == milestone_id {
                m.done = not m.done;
                return m.done;
            }
        }
    }
    raise ValueError("That milestone no longer exists.");
}

def:pub add_habit(
    title: str, days: list[int] | None = None, goal_id: str = "", today: str = ""
) -> str {
    _signed_in();
    picked = sorted(
        {
            int(d)
            # An omitted `days` can arrive as the string "None" over HTTP; default to daily.
            for d in (days if isinstance(days, list) else range(7))
            if 0 <= int(d) <= 6
        }
    );
    if not picked {
        raise ValueError("Pick at least one day for the habit.");
    }
    habit = Habit(
        title=_clean(title, 80, "A habit title"),
        days=picked,
        created=_day_or_today(today).isoformat()
    );
    root ++> habit;
    if goal_id {
        _find_goal(goal_id) +>:Supports():+> habit;
    }
    return jid(habit);
}

def:pub remove_habit(habit_id: str) -> bool {
    _signed_in();
    habit = _find_habit(habit_id);
    for c in [habit-->[?:CheckIn]] {
        del c;
    }
    del habit;
    return True;
}

def:pub check_in(habit_id: str, date: str = "", today: str = "") -> bool {
    _signed_in();
    habit = _find_habit(habit_id);
    now = _day_or_today(today);
    day = _parse_day(date) if date.strip() else now;
    if day > now or (now - day).days > 7 {
        raise ValueError("You can only check in for today or the past week.");
    }
    for c in [habit-->[?:CheckIn]] {
        if c.date == day.isoformat() {
            del c;
            return False;
        }
    }
    habit ++> CheckIn(date=day.isoformat());
    return True;
}

def:pub plan_day(today: str = "", now: str = "08:00", note: str = "") -> DayPlan {
    _signed_in();
    board = dashboard(today);
    habits = [
        HabitBrief(
            id=v.id, title=v.title, done=v.done_today, streak=v.streak, goal=v.goal
        )
        for v in board.habits
        if v.due_today
    ];
    goals = [
        GoalBrief(
            title=v.title,
            progress=v.progress,
            days_left=v.days_left,
            next_step=v.next_step
        ) for v in board.goals
    ];
    # Cap AI calls per account per server day so a runaway client cannot burn the key.
    allow_ai = False;
    profiles = [root-->[?:Profile]];
    if profiles and _ai_available() {
        me = profiles[0];
        stamp = datetime.date.today().isoformat();
        if me.ai_day != stamp {
            me.ai_day = stamp;
            me.ai_used = 0;
        }
        allow_ai = me.ai_used < AI_PLANS_PER_DAY;
        me.ai_used += 1 if allow_ai else 0;
    }
    return _plan_for(
        board.today, board.weekday, now, note, habits, goals, allow_ai=allow_ai
    );
}
