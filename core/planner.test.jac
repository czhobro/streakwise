import os;
import from pathlib { Path }
import from tempfile { TemporaryDirectory }
import from jaclang.testing.testing { JacTestClient }
import from core.coach { HabitBrief, GoalBrief, _rule_plan }

def call(client: JacTestClient, name: str, fields: dict[str, any] = {}) -> any {
    response = client.post("/function/" + name, json=fields);
    assert response.ok , response.text;
    return response.data["result"];
}

test "habits, streaks, goals and plans stay private per account" {
    os.environ.pop("ANTHROPIC_API_KEY", None);
    with TemporaryDirectory() as folder {
        client = JacTestClient.from_file(
            str(Path(__file__).with_name("planner.jac")), base_path=folder
        );
        try {
            assert not client.post("/function/dashboard", json={}).ok;
            for name in ["alice", "bob"] {
                assert client.register_user(name, "planner-secret-1").ok;
            }
            assert client.login("alice", "planner-secret-1").ok;
            assert call(client, "join", {"username": "alice"}) == "alice";
            assert not client.post("/function/join", json={"username": "bob"}).ok;

            goal = call(
                client,
                "add_goal",
                {"title": "Run a 10K", "target": "2026-10-31", "today": "2026-09-20"}
            );
            first = call(client, "add_milestone", {"goal_id": goal, "title": "Run 5K"});
            call(client, "add_milestone", {"goal_id": goal, "title": "Run 8K"});
            assert call(client, "toggle_milestone", {"milestone_id": first}) is True;
            assert not client.post("/function/add_goal", json={"title": "  "}).ok;
            assert not client.post(
                "/function/add_goal", json={"title": "x", "target": "soon"}
            ).ok;

            # Weekdays only (Mon-Fri); 2026-09-21 is a Monday.
            run = call(
                client,
                "add_habit",
                {
                    "title": "Run",
                    "days": [0, 1, 2, 3, 4],
                    "goal_id": goal,
                    "today": "2026-09-21"
                }
            );
            for day in ["2026-09-21", "2026-09-22", "2026-09-24", "2026-09-25"] {
                assert call(
                    client,
                    "check_in",
                    {"habit_id": run, "date": day, "today": "2026-09-28"}
                )
                    is True;
            }
            # Future and too-old check-ins are rejected.
            assert not client.post(
                "/function/check_in",
                json={"habit_id": run, "date": "2026-09-29", "today": "2026-09-28"}
            ).ok;
            assert not client.post(
                "/function/check_in",
                json={"habit_id": run, "date": "2026-09-01", "today": "2026-09-28"}
            ).ok;

            board = call(client, "dashboard", {"today": "2026-09-28"});
            habit = board["habits"][0];
            # Thu+Fri done, weekend off, Monday (today) still open -> streak 2.
            assert habit["streak"] == 2 , habit;
            assert habit["best"] == 2;
            assert habit["goal"] == "Run a 10K";
            assert habit["due_today"] and not habit["done_today"];
            assert habit["history"][-1] == "open";
            assert habit["rate30"] == 80;  # 4 of 5 past weekdays
            assert board["due_today"] == 1 and board["done_today"] == 0;
            g = board["goals"][0];
            assert g["progress"] == 50 and g["next_step"] == "Run 8K";
            assert g["days_left"] == 33 and g["habits"] == ["Run"];
            assert len(board["heatmap"]) == 28;

            # Checking in today extends the streak; toggling again undoes it.
            assert call(client, "check_in", {"habit_id": run, "today": "2026-09-28"})
                is True;
            assert call(client, "dashboard", {"today": "2026-09-28"})["habits"][0][
                "streak"
            ]
                == 3;
            assert call(client, "check_in", {"habit_id": run, "today": "2026-09-28"})
                is False;

            plan = call(client, "plan_day", {"today": "2026-09-28", "now": "09:10"});
            assert plan["ai"] is False;
            assert plan["blocks"][0]["time"] == "09:15";
            assert plan["blocks"][0]["habit_id"] == run;
            assert any(b["title"] == "Run 8K" for b in plan["blocks"]);

            # Bob cannot see or touch Alice's data.
            assert client.login("bob", "planner-secret-1").ok;
            call(client, "join", {"username": "bob"});
            assert call(client, "dashboard", {})["habits"] == [];
            assert not client.post("/function/check_in", json={"habit_id": run}).ok;
            assert not client.post("/function/remove_goal", json={"goal_id": goal}).ok;

            assert client.login("alice", "planner-secret-1").ok;
            assert call(client, "remove_goal", {"goal_id": goal}) is True;
            board = call(client, "dashboard", {"today": "2026-09-28"});
            assert board["goals"] == [] and board["habits"][0]["goal"] == "";
            assert call(client, "remove_habit", {"habit_id": run}) is True;
            assert call(client, "dashboard", {})["habits"] == [];

            # A check-in backfilled before the habit existed still lights up the heatmap.
            fresh = call(
                client, "add_habit", {"title": "Stretch", "today": "2026-09-28"}
            );
            call(
                client,
                "check_in",
                {"habit_id": fresh, "date": "2026-09-27", "today": "2026-09-28"}
            );
            board = call(client, "dashboard", {"today": "2026-09-28"});
            cell = board["heatmap"][-2];
            assert (cell["date"], cell["done"], cell["due"])
                == ("2026-09-27", 1, 1) , cell;
            assert board["heatmap"][-3]["due"] == 0;
            assert board["habits"][0]["streak"] == 1;
        } finally {
            client.close();
        }
    }
}

test "rule plan schedules open habits by streak, then nearest goals" {
    plan = _rule_plan(
        "06:00",
        [
            HabitBrief(id="a", title="Read", streak=1),
            HabitBrief(id="b", title="Stretch", streak=9),
            HabitBrief(id="c", title="Journal", done=True)
        ],
        [
            GoalBrief(title="Far", progress=10, days_left=90, next_step="Far step"),
            GoalBrief(title="Near", progress=40, days_left=3, next_step="Near step"),
            GoalBrief(title="Done", progress=100, next_step="")
        ]
    );
    titles = [b.title for b in plan.blocks];
    assert titles[:4] == ["Stretch", "Read", "Near step", "Far step"] , titles;
    assert plan.blocks[0].time == "07:00";
    assert titles[-1] == "Evening review";
    assert "Journal" not in titles;
    assert not plan.ai;
}
