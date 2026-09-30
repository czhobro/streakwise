import os;
import from unittest.mock { patch }
import from jaclang.byllm.lib { MockLLM, MockRawResponse }

def habits -> list[HabitBrief] {
    return [
        HabitBrief(id="h1", title="Stretch", streak=4),
        HabitBrief(id="h2", title="Read", done=True)
    ];
}

def goals -> list[GoalBrief] {
    return [
        GoalBrief(title="Run a 10K", progress=50, days_left=12, next_step="Run 8K")
    ];
}

def mock(content: str) -> MockLLM {
    return MockLLM(
        model_name="mockllm", config={"outputs": [MockRawResponse(content=content)]}
    );
}

test "AI plan is used when a key is set, and invented habit ids are dropped" {
    os.environ["ANTHROPIC_API_KEY"] = "test-key";
    model = mock(
        '{"focus":"Stretch first, then run.","ai":false,"blocks":['
            + '{"time":"17:00","title":"Stretch","minutes":15,"why":"Keep the 4-day streak.","habit_id":"h1"},'
            + '{"time":"17:30","title":"Run 8K","minutes":60,"why":"Next 10K step.","habit_id":"made-up"}]}'
    );
    try {
        with patch(_draft_plan.__module__ + ".llm", model) {
            plan = _plan_for(
                "2026-09-30",
                "Wed",
                "16:40",
                "class until 4:30" + "x" * 2000,
                habits(),
                goals()
            );
        }
        assert plan.ai;
        assert [b.title for b in plan.blocks] == ["Stretch", "Run 8K"];
        assert plan.blocks[0].habit_id == "h1";
        assert plan.blocks[1].habit_id == "";
        prompt = str(model.seen_prompts[0]);
        assert "class until 4:30" in prompt;
        assert "x" * 600 not in prompt;  # the note is capped at 500 characters
    } finally {
        os.environ.pop("ANTHROPIC_API_KEY", None);
    }
}

test "bad model output falls back to the rule-based plan" {
    os.environ["ANTHROPIC_API_KEY"] = "test-key";
    try {
        with patch(_draft_plan.__module__ + ".llm", mock("not JSON")) {
            plan = _plan_for("2026-09-30", "Wed", "08:00", "", habits(), goals());
        }
        assert not plan.ai;
        assert plan.blocks[0].title == "Stretch";
    } finally {
        os.environ.pop("ANTHROPIC_API_KEY", None);
    }
}

test "no key or an exhausted daily cap never calls the model" {
    model = mock('{"focus":"x","blocks":[]}');
    with patch(_draft_plan.__module__ + ".llm", model) {
        assert not _plan_for("2026-09-30", "Wed", "08:00", "", habits(), goals()).ai;
        os.environ["ANTHROPIC_API_KEY"] = "test-key";
        try {
            capped = _plan_for(
                "2026-09-30", "Wed", "08:00", "", habits(), goals(), allow_ai=False
            );
            assert not capped.ai;
        } finally {
            os.environ.pop("ANTHROPIC_API_KEY", None);
        }
    }
    assert len(model.seen_prompts) == 0;
}

test "clock helpers round and clamp" {
    assert _minutes_of("09:10") == 550;
    assert _minutes_of("nonsense") == 480;
    assert _clock_of(555) == "09:15";
    assert _rule_plan("23:30", habits(), goals()).blocks == [];
}
