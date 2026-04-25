# Headless / autonomous mode discipline

Load this when running with `claude -p "..."` (single-shot), via cron, or in a scheduled agent — anywhere there is no human in the loop to re-prompt you.

## The cardinal rule

**Never end a turn with a text-only response if the task isn't done.**

In headless mode, a text-only response ends the agent loop with no human to re-prompt you. The conversation is over. If the task isn't complete, you've abandoned it.

Every response that isn't the final result MUST include at least one tool call. If you have nothing to do, check the plan, verify outputs, or plan ahead — but DO call a tool.

## Use the full time budget

Don't stop early. The user is paying for time, not for a quick "I think I'm done." If time remains, iterate:

```
LOOP UNTIL TIME RUNS OUT:
1. Research the approach (read docs, find examples, check current APIs)
2. Implement the solution (write code, set up training)
3. Train and evaluate
4. Save / push the model to the required location
5. Improve: tune hyperparameters, try different data, adjust the recipe, try a different approach
6. Go to step 1
```

Don't ask "should I continue?" or "is this a good stopping point?" — there is nobody to answer.

## Hyperparameter tuning rule

Don't tune hyperparameters one-at-a-time by hand. Write a sweep script that launches a grid and evaluates each run automatically. **One well-designed sweep beats ten manual experiments.**

```python
# sweep.py
import subprocess
configs = []
for lr in [1e-5, 5e-5, 1e-4]:
    for batch in [8, 16, 32]:
        configs.append({"lr": lr, "batch": batch})

for cfg in configs:
    subprocess.run([
        "hf", "jobs", "run",
        "--flavor", "a100-large", "--timeout", "10800",
        "--secrets", "HF_TOKEN",
        "--detach",                              # don't block on logs
        "--", "python", "train.py",
        f"--lr={cfg['lr']}", f"--batch={cfg['batch']}",
        f"--run-name=sweep-lr{cfg['lr']}-bs{cfg['batch']}",
    ])
```

## Time budget management

Check the remaining time periodically. Reserve at least 10 minutes at the end for final evaluation and model saving — a model that's 99% trained but not pushed to Hub is **lost**.

```python
import time
start = time.time()
budget_seconds = 8 * 3600  # 8h
RESERVED_FOR_SAVE = 600    # 10 min

def time_left():
    return budget_seconds - (time.time() - start)

while time_left() > RESERVED_FOR_SAVE:
    # train one chunk / iteration
    ...

# Always save:
trainer.push_to_hub()
print("DASHBOARD_URL:", trackio.get_dashboard_url())
```

## When out of ideas

If you've tried 3 approaches and they're not converging, **go back to the literature.** There is always a paper you haven't read yet, and it probably has:

- A better dataset for the task
- A different training method that's more sample-efficient
- A trick (data augmentation, curriculum, mixing ratios) that the previous papers didn't have

Crawl deeper into citation graphs. Read papers that *cite* your current approach and improved on it. Try combining recipes from different papers. Re-read the task prompt for angles you missed. Re-read the training logs for clues.

## Definition of done (headless)

The task is **NOT** done until:

- The required output exists (final model on Hub, metrics file written, dataset uploaded, etc.)
- You have evaluated the model and confirmed it works (loss is reasonable, sample generations look sane)
- You have surfaced the deliverables to the user (Hub URLs in your final response)

If you stop before all three are true, you've failed the task.

## What you can skip

You CAN skip these things in headless mode (they're for human-in-the-loop):

- Asking "should I proceed?"
- Presenting option menus when a clear default exists
- Restating what the user said
- Asking for confirmation before submitting `hf jobs run` (when running in `yolo_mode`-equivalent)

## What you must NEVER skip

- Pre-flight checklist before submitting expensive jobs (still saves you from $1000 mistakes)
- Smoke testing the first job in a sweep before submitting the rest
- Reading actual error messages and logs (don't guess)
- Pushing to Hub (results lost if you skip this)

## Anti-patterns to watch for

- **"I've completed the task"** with no Hub URL — you didn't push it; check.
- **"Training is in progress, I'll check later"** with no scheduled job — there is no "later" in headless mode unless you scheduled one.
- **"I tried X and it failed, will try Y next session"** — there's no next session. Try Y now.
- **Looping on the same broken approach** — escalate to the doom-loop check (try a different tool / different approach / different paper).
- **Making the task feel "done" by lowering expectations** — never quietly redefine what "success" means.

## Dovetail with the main SKILL.md

The main SKILL.md instructs the 6-step research-driven loop. In headless mode, that loop is the **inner** loop. The **outer** loop is iteration over multiple attempts (different recipes, different sweeps, different papers) until time runs out or the deliverable is done.
