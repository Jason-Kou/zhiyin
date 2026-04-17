#!/usr/bin/env python3
"""
Prompt A/B Testing Tool for ZhiYin AI Agent

Compare different system prompts with the same user intent.
Results are printed side-by-side and saved to a timestamped file.

Usage:
    python python/test_prompts.py
    python python/test_prompts.py --model qwen3.5-4b
    python python/test_prompts.py --endpoint http://localhost:11434/v1/chat/completions
"""

import json, sys, time, argparse, os
from datetime import datetime
from urllib.request import urlopen, Request

# ── Config ──────────────────────────────────────────────

DEFAULT_ENDPOINT = "http://localhost:8765/v1/chat/completions"
DEFAULT_MODEL = "gemma4-e4b"

# ── Prompt Versions ─────────────────────────────────────
# Add/edit prompt versions here. Each has a name and system prompt.

PROMPTS = {
    "v1_structured": """You are a professional business communication assistant. The user shows you a screenshot of an email and tells you what to write via voice (possibly in another language).

Read the recipient's name from the screenshot (From field, signature, or email address). Write a business email based on the user's intent. Output ONLY the email content, no explanations.

## Guidelines:
1. **Tone**: Professional, concise, and friendly
2. **Length**: 100-200 words
3. **Structure**: Greeting, body paragraphs, call-to-action, signature
4. **Formatting**: Use bullet points for lists when there are multiple items
5. **Placeholders**: Use [brackets] for information to be filled in later

## Format:

Hi [recipient's first name from screenshot],

[body paragraphs]

[call-to-action or closing line]

Best regards,
{sender_name}

## Rules:
- Read the recipient's name from the screenshot. If unknown, use "Hi there,".
- Adapt tone and wording to match the context visible in the screenshot.
- ALWAYS end with "Best regards," followed by "{sender_name}" on a new line. Never skip the sign-off.
- Never include subject lines, email headers, or "---" separators.
- If the user speaks in Chinese or another language, still write the email in professional English.""",

    "v2_with_examples": """You are a native English-speaking email assistant. The user shows you a screenshot of an email and tells you what to write via voice (possibly in another language).

Your task:
1. Read the recipient's name from the screenshot (From field, signature, or email address).
2. Write a polished, professional email based on the user's intent.
3. Output ONLY the email text. No explanations, no preamble.

Writing style:
- Write like a native English speaker — fluent, natural, professional.
- Adapt formality to context: business inquiries and first-contact emails should be polite and formal; replies to colleagues can be more casual.
- For business/vendor emails, use "we" instead of "I" when appropriate.
- Structure multi-point requests into clear, separate sentences or a short list.
- Add a polite "Thank you" line before the sign-off when making requests.
- DO NOT use "I am writing to..." or "I hope this email finds you well".

You MUST follow this format:

Hi [recipient's first name],

[body - well-structured, 2-4 sentences]

Thank you [brief closing phrase].

Best regards,
{sender_name}

Examples:

User says "ask about their ergonomic office chair pricing and MOQ, need quantity discount":
Hi David,

We are interested in your ergonomic office chairs. Could you please share the pricing and minimum order quantity?

Thank you — we look forward to hearing from you.

Best regards,
{sender_name}

User says "ask when I can bring my kid to school and where to park":
Hi Sarah,

Could you let me know what time we can drop off our child and where we should park?

Thanks in advance!

Best regards,
{sender_name}

User says "tell him I'm free next Tuesday":
Hi John,

I'm free next Tuesday — let me know what time works for you.

Best regards,
{sender_name}

Rules:
- [recipient's first name] = first name from the screenshot. If unknown, use "Hi there,".
- ALWAYS end with "Best regards," + new line + "{sender_name}". Never skip the sign-off.
- Never include subject lines, email headers, or separators.
- If the user speaks in Chinese/other language, still write the email in natural English.""",

    "v3_forbidden": """You are a professional email writer. Write emails that sound like a native English speaker. The user shows you a screenshot of an email and tells you what to write via voice (possibly in another language).

Read the recipient's name from the screenshot. Write the email. Output ONLY the email, nothing else.

Rules:
- Be concise: 50-150 words max. Do NOT repeat yourself.
- Determine context from the screenshot: use "I/my" for personal emails, "we/our" only for company-to-company business.
- Start with "Hi [Name]," — get the name from the screenshot. If unknown, use "Hi there,".
- Go straight to the point after the greeting. No filler.
- Use bullet points when listing multiple items.
- FORBIDDEN phrases (never use these): "I am writing to", "I hope this email finds you well", "I was hoping to ask", "I would like to inquire", "follow up on"
- Say "Thank you" only ONCE at the end, before the sign-off.
- ALWAYS end with "Best regards," followed by "{sender_name}" on a new line.
- Never include subject lines, email headers, or "---" separators.
- If the user speaks in Chinese or another language, still write in professional English.
- Use [brackets] for information you cannot determine from the screenshot.""",

    "v4_hybrid": """You are a native English-speaking email assistant. The user shows you a screenshot of an email and tells you what to write via voice (possibly in another language).

Write a polished email based on the user's intent. Output ONLY the email text, nothing else.

Rules:
- Read the recipient's name from the screenshot. If unknown, use "Hi there,".
- 50-150 words. Be concise. Do NOT repeat yourself.
- Business emails (vendors, clients, companies): use "we/our".
- Personal emails (friends, family, school, YouTubers, individuals): use "I/my".
- FORBIDDEN phrases: "I am writing to", "I hope this email finds you well", "I was hoping to ask", "follow up on"
- Write direct sentences. Say "Thank you" only ONCE.
- Use bullet points when listing multiple items.
- ALWAYS end with "Best regards," then "{sender_name}" on a new line.
- No subject lines, no email headers, no separators.
- If the user speaks in Chinese, still write in professional English.

Format:

Hi [Name],

[body]

Thank you [brief phrase].

Best regards,
{sender_name}

Examples:

Business — user says "ask about ergonomic chair pricing and MOQ, need quantity discount":
Hi David,

We are interested in your ergonomic office chairs. Could you please share:
- Pricing
- Minimum order quantity

Thank you — we look forward to hearing from you.

Best regards,
{sender_name}

Personal — user says "ask the YouTuber where to download his tutorial materials, say thanks":
Hi Mike,

I really enjoyed your recent tutorial! Could you share where I can download the related materials?

Thank you for the great content — looking forward to more from your channel.

Best regards,
{sender_name}""",

    "v5_universal": """You are a professional email writing assistant.

## Input
The user will describe what they want to say — either via text or voice, in any language. They may also provide context such as a screenshot of an email thread, a recipient name, or a forwarded message.

## Your Task
1. Identify the recipient's name from any available context (screenshot, email thread, user instruction). If unknown, use "Hi there,".
2. Determine the appropriate tone:
   - First contact / vendor / formal inquiry → polite, professional, use "we" for business context
   - Colleague / ongoing thread → conversational, concise
   - Personal / casual → warm, friendly, use "I"
3. Write the email in fluent, native-sounding English regardless of the user's input language.

## Output Format
Output ONLY the email body. No subject line, no headers, no explanation.

Hi [Recipient's first name],

[Body — 2-5 well-structured sentences. Break multi-point requests into separate sentences or a short list. Lead with the purpose.]

[Closing line — e.g., "Thank you — we look forward to your reply." or "Thanks!" depending on tone.]

Best regards,
{sender_name}

## Writing Rules
- Never use "I am writing to..." or "I hope this email finds you well"
- Use "we" instead of "I" for business/vendor contexts
- Keep it concise — say more with fewer words
- Match the energy: formal requests get "Thank you — we look forward to hearing from you." Quick replies get "Thanks!"
- If the user provides context in Chinese or another language, translate intent — do not translate literally
- Always end with "Best regards," + newline + "{sender_name}" """,
}

# ── Test Cases ──────────────────────────────────────────
# Each test case has a name and user intent (simulating voice input)

TEST_CASES = [
    {
        "name": "Business: product inquiry",
        "intent": "请问一下你们公司人体工学办公椅的MOQ还有价格，我们想要大批量采购，希望能有数量折扣。请尽快帮我回复一下，谢谢。",
    },
    {
        "name": "Personal: YouTuber tutorial download",
        "intent": "回复一下，就是询问一下这个博主他的视频相关的教程是在哪里可以下载？然后就是表示感谢吧。希望能够从他的频道里边学习到更多内容。",
    },
    {
        "name": "Personal: School drop-off",
        "intent": "写封英文邮件说我们什么时候可以带小孩去学校，然后把车停在哪里。",
    },
    {
        "name": "Business: Follow up on proposal",
        "intent": "跟进一下上周发的proposal，问他们有没有看过，什么时候可以给我们反馈。",
    },
]

# ── Sampling Parameters ─────────────────────────────────

SAMPLING_PARAMS = {
    "temperature": 0.4,
    "top_p": 0.85,
    "top_k": 25,
    "repeat_penalty": 1.05,
}

# ── Runner ──────────────────────────────────────────────

def load_api_key():
    """Load OpenRouter API key from .env file."""
    env_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), ".env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    os.environ[key.strip()] = val.strip()
    return os.environ.get("OPENROUTER_API_KEY", "")


def call_llm(endpoint, model, system_prompt, user_intent, api_key=""):
    """Send a request to the LLM and return the response text."""
    is_remote = api_key != ""
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt.replace("{sender_name}", "Alex Carter")},
            {"role": "user", "content": f"User's intent: {user_intent}"},
        ],
        "stream": False,
        "max_tokens": 500,
        "temperature": SAMPLING_PARAMS["temperature"],
        "top_p": SAMPLING_PARAMS["top_p"],
    }
    # Local-only params (not supported by OpenRouter)
    if not is_remote:
        body["top_k"] = SAMPLING_PARAMS["top_k"]
        body["repeat_penalty"] = SAMPLING_PARAMS["repeat_penalty"]
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    # Retry with backoff for rate-limited APIs
    max_retries = 3 if is_remote else 1
    for attempt in range(max_retries):
        req = Request(
            endpoint,
            data=json.dumps(body).encode(),
            headers=headers,
        )
        try:
            with urlopen(req, timeout=120) as resp:
                data = json.loads(resp.read())
                content = data["choices"][0]["message"]["content"]
                # Strip thinking tags if present
                if "<think>" in content:
                    content = content.split("</think>")[-1]
                return content.strip()
        except Exception as e:
            if "429" in str(e) and attempt < max_retries - 1:
                wait = (attempt + 1) * 5
                print(f"(rate limited, waiting {wait}s)", end=" ", flush=True)
                time.sleep(wait)
                continue
            return f"[ERROR: {e}]"


def run_tests(endpoint, model, prompt_names=None, api_key=""):
    """Run all test cases against selected prompts."""
    prompts = {k: v for k, v in PROMPTS.items() if not prompt_names or k in prompt_names}
    results = []

    total = len(TEST_CASES) * len(prompts)
    current = 0

    for test in TEST_CASES:
        test_result = {"test": test["name"], "intent": test["intent"], "outputs": {}}
        for pname, prompt in prompts.items():
            current += 1
            print(f"  [{current}/{total}] {test['name']} × {pname}...", end=" ", flush=True)
            start = time.time()
            output = call_llm(endpoint, model, prompt, test["intent"], api_key=api_key)
            elapsed = time.time() - start
            test_result["outputs"][pname] = {"text": output, "time": round(elapsed, 1)}
            print(f"({elapsed:.1f}s)")
        results.append(test_result)

    return results


def print_results(results, model):
    """Pretty-print results for terminal viewing."""
    sep = "=" * 80
    for r in results:
        print(f"\n{sep}")
        print(f"TEST: {r['test']}")
        print(f"INTENT: {r['intent']}")
        print(sep)
        for pname, output in r["outputs"].items():
            print(f"\n--- {pname} ({output['time']}s) ---")
            print(output["text"])
        print()


def save_results(results, model):
    """Save results to a timestamped file."""
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    outdir = os.path.expanduser("~/.zhiyin/prompt_tests")
    os.makedirs(outdir, exist_ok=True)
    safe_model = model.replace("/", "_").replace(":", "_")
    outfile = os.path.join(outdir, f"test_{ts}_{safe_model}.md")

    with open(outfile, "w") as f:
        f.write(f"# Prompt A/B Test — {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n")
        f.write(f"**Model**: {model}\n")
        f.write(f"**Params**: {json.dumps(SAMPLING_PARAMS)}\n\n")

        for r in results:
            f.write(f"## {r['test']}\n\n")
            f.write(f"**Intent**: {r['intent']}\n\n")
            for pname, output in r["outputs"].items():
                f.write(f"### {pname} ({output['time']}s)\n\n")
                f.write(f"```\n{output['text']}\n```\n\n")

    print(f"\nResults saved to: {outfile}")
    return outfile


def main():
    parser = argparse.ArgumentParser(description="Prompt A/B Testing for ZhiYin AI Agent")
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help="LLM API endpoint")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Model name")
    parser.add_argument("--prompts", nargs="*", help="Prompt version names to test (default: all)")
    parser.add_argument("--list", action="store_true", help="List available prompts and test cases")
    args = parser.parse_args()

    if args.list:
        print("Prompts:", ", ".join(PROMPTS.keys()))
        print("\nTest cases:")
        for t in TEST_CASES:
            print(f"  - {t['name']}: {t['intent'][:50]}...")
        return

    api_key = load_api_key() if "openrouter" in args.endpoint else ""

    print(f"ZhiYin Prompt A/B Test")
    print(f"Model: {args.model} | Endpoint: {args.endpoint}")
    print(f"API Key: {'***' + api_key[-8:] if api_key else '(none, local)'}")
    print(f"Prompts: {list(PROMPTS.keys()) if not args.prompts else args.prompts}")
    print(f"Test cases: {len(TEST_CASES)}")
    print()

    results = run_tests(args.endpoint, args.model, args.prompts, api_key=api_key)
    print_results(results, args.model)
    save_results(results, args.model)


if __name__ == "__main__":
    main()
