import from "@jac/mobui" {
    View,
    Text,
    TextInput,
    Pressable,
    ScrollView,
    useWindowDimensions
}
import from "@jac/runtime" {
    jacSetToken,
    __getApiBaseUrl,
    jacLogout,
    jacIsLoggedIn,
    __getLocalStorage,
    __setLocalStorage
}
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
import from core.coach { DayPlan }
import from core.theme { S, C }

glob DAY_LETTERS: list[str] = ["M", "T", "W", "T", "F", "S", "S"];

def pad(n: float) -> str {
    text = str(n);
    return text if len(text) >= 2 else "0" + text;
}

def local_today -> str {
    d = new(Date);
    return f"{d.getFullYear()}-{pad(d.getMonth() + 1)}-{pad(d.getDate())}";
}

def local_now -> str {
    d = new(Date);
    return f"{pad(d.getHours())}:{pad(d.getMinutes())}";
}

def heat_color(done: int, due: int) -> str {
    if due == 0 {
        return C.line if done == 0 else C.accent;
    }
    ratio = done / due;
    if ratio >= 1 {
        return C.accent;
    }
    if ratio >= 0.5 {
        return "#7fa184";
    }
    return "#c9d8c1" if ratio > 0 else C.miss;
}

def dot_color(state: str) -> str {
    if state == "done" {
        return C.accent;
    }
    if state == "miss" {
        return C.miss;
    }
    return C.soft if state == "open" else "#f1f1ea";
}

def Button(
    label: str, action: Callable, quiet: bool = False, disabled: bool = False
) -> JsxElement {
    return
        <Pressable
            accessibilityRole="button"
            accessibilityLabel={label}
            disabled={disabled}
            onPress={action}
            style={[
                S.button,
                S.quiet if quiet else {},
                {"opacity": 0.45 if disabled else 1}
            ]}
        >
            <Text style={[S.buttonText, S.quietText if quiet else {}]}>{label}</Text>
        </Pressable>;
}

def Chip(label: str, on: bool, action: Callable) -> JsxElement {
    return
        <Pressable
            accessibilityRole="button"
            accessibilityState={{"selected": on}}
            accessibilityLabel={label}
            onPress={action}
            style={[S.chip, S.chipOn if on else {}]}
        >
            <Text style={[S.chipText, {"color": "#fff"} if on else {}]}>{label}</Text>
        </Pressable>;
}

def HabitRow(
    habit: HabitView,
    busy: bool,
    onToggle: Callable,
    onDelete: Callable,
    confirming: bool
) -> JsxElement {
    return
        <View style={S.habit} testID={"habit-" + habit.id}>
            <Pressable
                accessibilityRole="checkbox"
                accessibilityState={{"checked": habit.done_today}}
                accessibilityLabel={"Check in " + habit.title}
                disabled={busy}
                onPress={onToggle}
                style={[S.check, S.checked if habit.done_today else {}]}
            >
                <Text style={S.checkMark}>{"✓" if habit.done_today else ""}</Text>
            </Pressable>
            <View style={{"flex": 1, "minWidth": 0}}>
                <Text style={S.name}>{habit.title}</Text>
                <Text style={S.small}>
                    {habit.goal + " · " if habit.goal else ""}{habit.rate30}% last 30 days · best {habit.best}
                </Text>
                <View style={S.dots}>
                    {for (i, state) in enumerate(habit.history) {
                        <View
                            key={i}
                            style={[S.dot, {"backgroundColor": dot_color(state)}]}
                        />
                    }}
                </View>
            </View>
            <Text style={S.streak}>
                {"🔥 " + String(habit.streak) if habit.streak else ""}
            </Text>
            <Pressable
                accessibilityRole="button"
                accessibilityLabel={"Delete " + habit.title}
                onPress={onDelete}
                disabled={busy}
            >
                <Text style={[S.small, {"color": "#8c3524"} if confirming else {}]}>
                    {"Delete?" if confirming else "✕"}
                </Text>
            </Pressable>
        </View>;
}

def:pub PlannerApp(remote: bool = False) -> JsxElement {
    has board: Dashboard = Dashboard(),
        plan: DayPlan | None = None,
        username: str = "",
        password: str = "",
        signup: bool = False,
        logged: bool = False,
        busy: bool = False,
        loading: bool = False,
        error: str = "",
        server: str = "",
        connected: bool = not remote,
        habit_title: str = "",
        habit_days: list[int] = [0, 1, 2, 3, 4, 5, 6],
        habit_goal: str = "",
        goal_title: str = "",
        goal_why: str = "",
        goal_target: str = "",
        step_goal: str = "",
        step_title: str = "",
        note: str = "",
        confirm: str = "";
    wide = useWindowDimensions().width >= 860;

    async def refresh {
        if not logged {
            return;
        }
        loading = True;
        error = "";
        try {
            board = await dashboard(local_today());
            if not board.viewer {
                jacLogout();
                logged = False;
            }
        } except Exception {
            error = "Could not load your planner. Check your connection and try again.";
        } finally {
            loading = False;
        }
    }

    async def connect {
        if not server.startswith("http://") and not server.startswith("https://") {
            error = "Enter a server address starting with http:// or https://.";
            return;
        }
        server = server.rstrip("/");
        globalThis.__JAC_API_BASE_URL__ = server;
        __setLocalStorage("planner_server", server);
        jacLogout();
        logged = False;
        connected = True;
        error = "";
    }

    can with entry {
        logged = jacIsLoggedIn();
        username = __getLocalStorage("planner_username") or "";
        server = __getLocalStorage("planner_server") or "http://127.0.0.1:8000";
        if remote and __getLocalStorage("planner_server") {
            globalThis.__JAC_API_BASE_URL__ = server;
            connected = True;
        }
        if connected and logged {
            refresh();
        }
    }

    async def authenticate {
        if busy {
            return;
        }
        busy = True;
        error = "";
        try {
            if not username.strip() or not password {
                error = "Enter a username and password.";
                return;
            }
            identity = {"type": "username", "value": username.strip()};
            payload: dict[str, any] = {
                "credential": {"type": "password", "password": password}
            };
            if signup {
                payload["identities"] = [identity];
            } else {
                payload["identity"] = identity;
            }
            response = await fetch(
                __getApiBaseUrl() + "/user/" + ("register" if signup else "login"),
                {
                    "method": "POST",
                    "headers": {"Content-Type": "application/json"},
                    "body": JSON.stringify(payload)
                }
            );
            result: any = await response.json();
            if not response.ok {
                error = result.error.message or "Could not sign in.";
                return;
            }
            jacSetToken(result.data.token);
            username = await join(username.strip());
            __setLocalStorage("planner_username", username);
            logged = True;
            password = "";
            await refresh();
        } except Exception {
            error = "Could not sign in. Check your connection and try again.";
        } finally {
            busy = False;
        }
    }

    async def act(kind: str, id: str = "") {
        if busy {
            return;
        }
        busy = True;
        error = "";
        try {
            today = local_today();
            if kind == "check" {
                await check_in(id, today, today);
            } elif kind == "habit" {
                await add_habit(habit_title, habit_days, habit_goal, today);
                habit_title = "";
                habit_goal = "";
                habit_days = [0, 1, 2, 3, 4, 5, 6];
            } elif kind == "goal" {
                await add_goal(goal_title, goal_why, goal_target, today);
                goal_title = "";
                goal_why = "";
                goal_target = "";
            } elif kind == "step" {
                await add_milestone(id, step_title);
                step_title = "";
            } elif kind == "toggle_step" {
                await toggle_milestone(id);
            } elif kind == "del_habit" or kind == "del_goal" {
                if confirm != id {
                    confirm = id;
                    return;
                }
                confirm = "";
                if kind == "del_habit" {
                    await remove_habit(id);
                } else {
                    await remove_goal(id);
                }
            } elif kind == "plan" {
                plan = await plan_day(today, local_now(), note);
            }
            board = await dashboard(today);
        } except Exception as e {
            raw: any = e;
            message = str(raw.message or "");
            error = message
                if len(message) < 120 and message
                else "That action did not complete. Refresh and try again.";
        } finally {
            busy = False;
        }
    }

    async def logout {
        jacLogout();
        logged = False;
        password = "";
        plan = None;
        board = Dashboard();
        error = "";
    }

    today_label = new(Date).toLocaleDateString(
        "en-US", {"weekday": "long", "month": "long", "day": "numeric"}
    );
    due = [
        h
        for h in board.habits
        if h.due_today
    ];
    plan_focus = plan.focus if plan else "";
    plan_blocks = plan.blocks if plan else [];
    plan_ai = plan.ai if plan else False;
    resting = [
        h
        for h in board.habits
        if not h.due_today
    ];

    auth_card = <View
        style={[S.card, {"maxWidth": 420, "width": "100%", "alignSelf": "center"}]}
    >
        <Text style={S.name}>
            {"Start building streaks." if signup else "Welcome back."}
        </Text>
        <Text style={S.small}>
            Your goals and habits sync across web, phone, and terminal.
        </Text>
        <TextInput
            accessibilityLabel="Username"
            style={S.input}
            placeholder="Username"
            value={username}
            autoCapitalize="none"
            autoCorrect={False}
            onChangeText={lambda (t: str) { username = t; }}
        />
        <TextInput
            accessibilityLabel="Password"
            style={S.input}
            placeholder="Password"
            value={password}
            secureTextEntry={True}
            autoCapitalize="none"
            autoCorrect={False}
            onChangeText={lambda (t: str) { password = t; }}
            onSubmitEditing={authenticate}
        />
        <Button
            label={"Please wait…"
                if busy
                else "Create account" if signup else "Sign in"}
            action={authenticate}
            disabled={busy}
        />
        <Button
            label={"I already have an account"
                if signup
                else "New here? Create an account"}
            quiet={True}
            disabled={busy}
            action={lambda {
                signup = not signup;
                error = "";
            }}
        />
    </View>;

    connect_card = <View style={S.card}>
        <Text style={S.name}>Connect to your planner server</Text>
        <Text style={S.small}>
            iOS simulator: http://127.0.0.1:8000 · Android emulator: http://10.0.2.2:8000 · phone: http://YOUR-MAC-IP:8000
        </Text>
        <TextInput
            accessibilityLabel="Server address"
            style={S.input}
            value={server}
            autoCapitalize="none"
            onChangeText={lambda (t: str) { server = t; }}
        />
        <Button label="Connect" action={connect}/>
    </View>;

    today_card = <View style={S.card}>
        <View style={S.between}>
            <Text style={S.eyebrow}>TODAY'S HABITS</Text>
            <Button
                label={"Loading…" if loading else "Refresh"}
                quiet={True}
                action={refresh}
                disabled={loading}
            />
        </View>
        {<Text style={S.body}>
            No habits yet. Add your first one below. Small and daily beats big and rare.
        </Text>
            if len(board.habits) == 0
            else None}
        {for h in due {
            <HabitRow
                key={h.id}
                habit={h}
                busy={busy}
                confirming={confirm == h.id}
                onToggle={lambda { act("check", h.id); }}
                onDelete={lambda { act("del_habit", h.id); }}
            />
        }}
        {<Text style={S.small}>
            Resting today: {", ".join([h.title for h in resting])}
        </Text>
            if len(resting) > 0
            else None}
    </View>;

    habit_form = <View style={S.card}>
        <Text style={S.eyebrow}>NEW HABIT</Text>
        <TextInput
            accessibilityLabel="Habit title"
            style={S.input}
            placeholder="e.g. Read 20 pages"
            placeholderTextColor={C.muted}
            value={habit_title}
            maxLength={80}
            onChangeText={lambda (t: str) { habit_title = t; }}
        />
        <View style={S.row}>
            {for (i, letter) in enumerate(DAY_LETTERS) {
                <Chip
                    key={i}
                    label={letter}
                    on={i in habit_days}
                    action={lambda { habit_days = [
                        d
                        for d in habit_days
                        if d != i
                    ]
                        if i in habit_days
                        else sorted(habit_days + [i]); }}
                />
            }}
        </View>
        {<View style={S.row}>
            <Text style={S.small}>Supports:</Text>
            {for g in board.goals {
                <Chip
                    key={g.id}
                    label={g.title}
                    on={habit_goal == g.id}
                    action={lambda { habit_goal = "" if habit_goal == g.id else g.id; }}
                />
            }}
        </View>
            if len(board.goals) > 0
            else None}
        <Button
            label="Add habit"
            action={lambda { act("habit"); }}
            disabled={busy or not habit_title.strip() or len(habit_days) == 0}
        />
    </View>;

    plan_card = <View style={S.card}>
        <Text style={S.eyebrow}>PLAN MY DAY</Text>
        <TextInput
            accessibilityLabel="Anything about today?"
            style={[S.input, S.composer]}
            placeholder="Optional: energy, classes, how much time you have…"
            placeholderTextColor={C.muted}
            value={note}
            multiline={True}
            maxLength={500}
            onChangeText={lambda (t: str) { note = t; }}
        />
        <Button
            label={"Planning…" if busy else "Plan the rest of my day"}
            action={lambda { act("plan"); }}
            disabled={busy}
        />
        {<View style={S.stack} testID="plan">
            <Text style={S.body}>{plan_focus}</Text>
            {for (i, b) in enumerate(plan_blocks) {
                <View key={i} style={S.block}>
                    <Text style={S.time}>{b.time}</Text>
                    <View style={{"flex": 1}}>
                        <Text style={S.name}>{b.title} · {b.minutes} min</Text>
                        <Text style={S.small}>{b.why}</Text>
                    </View>
                </View>
            }}
            <Text style={S.small}>
                {"✦ Planned by AI"
                    if plan_ai
                    else "Rule-based plan (set ANTHROPIC_API_KEY on the server for AI plans)"}
            </Text>
        </View>
            if plan
            else None}
    </View>;

    heat_card = <View style={S.card}>
        <Text style={S.eyebrow}>LAST 4 WEEKS</Text>
        <View style={S.heat}>
            {for day in board.heatmap {
                <View
                    key={day.date}
                    accessibilityLabel={f"{day.date}: {day.done} of {day.due}"}
                    style={[S.cell, {"backgroundColor": heat_color(day.done, day.due)}]}
                />
            }}
        </View>
        <Text style={S.small}>
            Each square is a day. Darker means more habits done.
        </Text>
    </View>;

    goals_card = <View style={S.stack}>
        <Text style={S.eyebrow}>GOALS</Text>
        {for g in board.goals {
            <View key={g.id} style={S.card} testID={"goal-" + g.id}>
                <View style={S.between}>
                    <Text style={[S.name, {"flex": 1, "fontSize": 16}]}>{g.title}</Text>
                    <Text style={S.small}>
                        {(
                            "Due today"
                                if g.days_left == 0
                                else (
                                    "Overdue"
                                        if g.days_left < 0
                                        else f"{g.days_left} days left"
                                )
                        )
                            if g.target
                            else ""}
                    </Text>
                </View>
                {<Text style={S.small}>{g.why}</Text> if g.why else None}
                <View style={S.bar}>
                    <View style={[S.barFill, {"width": f"{g.progress}%"}]}/>
                </View>
                <Text style={S.small}>
                    {g.progress}% · {len(g.milestones)} milestones{" · habits: "
                        + ", ".join(g.habits)
                        if len(g.habits) > 0
                        else ""}
                </Text>
                {for m in g.milestones {
                    <Pressable
                        key={m.id}
                        accessibilityRole="checkbox"
                        accessibilityState={{"checked": m.done}}
                        accessibilityLabel={"Milestone: " + m.title}
                        onPress={lambda { act("toggle_step", m.id); }}
                        disabled={busy}
                        style={S.row}
                    >
                        <Text style={S.name}>{"☑" if m.done else "☐"}</Text>
                        <Text
                            style={[
                                S.body,
                                {"textDecorationLine": "line-through", "color": C.muted}
                                    if m.done
                                    else {}
                            ]}
                        >
                            {m.title}
                        </Text>
                    </Pressable>
                }}
                {<View style={S.stack}>
                    <TextInput
                        accessibilityLabel="New milestone"
                        style={S.input}
                        placeholder="Next milestone"
                        placeholderTextColor={C.muted}
                        value={step_title}
                        maxLength={120}
                        onChangeText={lambda (t: str) { step_title = t; }}
                        onSubmitEditing={lambda { act("step", g.id); }}
                    />
                    <Button
                        label="Add milestone"
                        action={lambda { act("step", g.id); }}
                        disabled={busy or not step_title.strip()}
                    />
                </View>
                    if step_goal == g.id
                    else None}
                <View style={S.row}>
                    <Button
                        label={"Close" if step_goal == g.id else "+ Milestone"}
                        quiet={True}
                        action={lambda {
                            step_goal = "" if step_goal == g.id else g.id;
                            step_title = "";
                        }}
                    />
                    <Button
                        label={"Really delete?" if confirm == g.id else "Delete goal"}
                        quiet={True}
                        action={lambda { act("del_goal", g.id); }}
                        disabled={busy}
                    />
                </View>
            </View>
        }}
        <View style={S.card}>
            <Text style={S.eyebrow}>NEW GOAL</Text>
            <TextInput
                accessibilityLabel="Goal title"
                style={S.input}
                placeholder="e.g. Run a 10K"
                placeholderTextColor={C.muted}
                value={goal_title}
                maxLength={80}
                onChangeText={lambda (t: str) { goal_title = t; }}
            />
            <TextInput
                accessibilityLabel="Why it matters"
                style={S.input}
                placeholder="Why it matters (optional)"
                placeholderTextColor={C.muted}
                value={goal_why}
                maxLength={200}
                onChangeText={lambda (t: str) { goal_why = t; }}
            />
            <TextInput
                accessibilityLabel="Target date"
                style={S.input}
                placeholder="Target date YYYY-MM-DD (optional)"
                placeholderTextColor={C.muted}
                value={goal_target}
                autoCapitalize="none"
                onChangeText={lambda (t: str) { goal_target = t; }}
            />
            <Button
                label="Add goal"
                action={lambda { act("goal"); }}
                disabled={busy or not goal_title.strip()}
            />
        </View>
    </View>;

    signed_in = <View style={S.stack}>
        <View style={[S.row, {"gap": 28}]}>
            <View>
                <Text testID="done-today" style={S.stat}>
                    {board.done_today}/{board.due_today}
                </Text>
                <Text style={S.small}>habits done today</Text>
            </View>
            <View>
                <Text style={[S.stat, {"color": C.flame}]}>
                    {"🔥"}{board.top_streak}
                </Text>
                <Text style={S.small}>longest active streak</Text>
            </View>
            <View>
                <Text style={S.stat}>{len(board.goals)}</Text>
                <Text style={S.small}>goals in motion</Text>
            </View>
        </View>
        <View
            style={{
                "gap": 24,
                "alignItems": "stretch",
                "flexDirection": "row" if wide else "column"
            }}
        >
            <View style={[S.stack, {"flex": 1.3, "minWidth": 0}]}>
                {today_card}{plan_card}{habit_form}
            </View>
            <View style={[S.stack, {"flex": 1, "minWidth": 0}]}>
                {heat_card}{goals_card}
            </View>
        </View>
    </View>;

    return
        <ScrollView
            style={S.screen}
            contentContainerStyle={S.page}
            keyboardShouldPersistTaps="handled"
        >
            <View style={S.header}>
                <Text style={S.brand}>
                    streakwise
                    <Text style={S.quietText}>.</Text>
                </Text>
                <Text style={S.eyebrow}>{today_label.upper()}</Text>
            </View>
            <View style={S.stack}>
                <Text accessibilityRole="header" style={S.title}>
                    {"Hi " + board.viewer + ". Keep the chain going."
                        if logged and board.viewer
                        else "Small steps, every day."}
                </Text>
                <Text style={S.subtitle}>
                    Goals, daily habits, streaks, and an AI coach that plans your day.
                </Text>
            </View>
            {<Text accessibilityRole="alert" style={S.error}>{error}</Text>
                if error
                else None}
            {connect_card if not connected else signed_in if logged else auth_card}
            <View style={[S.footer, S.between, {"flexWrap": "wrap"}]}>
                <Text style={S.small}>
                    Streakwise · web, mobile & CLI on one server
                </Text>
                <View style={S.row}>
                    {<Button
                        label="Change server"
                        quiet={True}
                        action={lambda {
                            jacLogout();
                            logged = False;
                            connected = False;
                            error = "";
                        }}
                    />
                        if remote and connected
                        else None}{<Button
                        label="Sign out"
                        quiet={True}
                        action={logout}
                    />
                        if logged and connected
                        else None}
                </View>
            </View>
        </ScrollView>;
}
