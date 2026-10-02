#!/usr/bin/env python3
"""Terminal chat with the LLM loaded on the AMD NPU server (FastFlowLM, OpenAI API).

Usage: chat.py <server url> <model> <think 0|1>
Commands: /reset clears the conversation, /exit (or Ctrl+D) quits, Ctrl+C stops an answer.
Pasted text, newlines included, is sent as one message when you press Enter.
Standard library only.
"""

import json
import sys
import urllib.request

try:
    import readline  # line editing and history for input()

    # Python turns bracketed paste off, which makes each line of a multi-line paste its own
    # message. With it on, a paste stays in the input line until Enter.
    readline.parse_and_bind("set enable-bracketed-paste on")
except ImportError:
    pass

DIM, BOLD, RESET = "\033[2m", "\033[1m", "\033[0m"
# The input prompt marks its colour codes as invisible (\001...\002). Otherwise readline counts them
# as text and wraps a long line in the wrong place, redrawing it over itself.
PROMPT = f"\001{BOLD}\002you ›\001{RESET}\002 "


def stream(url, model, messages, think):
    body = {
        "model": model,
        "messages": messages,
        "stream": True,
        "chat_template_kwargs": {"enable_thinking": bool(think)},
    }
    request = urllib.request.Request(
        f"{url}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                return
            try:
                yield json.loads(data)
            except json.JSONDecodeError:
                continue


def main():
    url, model, think = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
    print(f"{BOLD}{model}{RESET} on the AMD NPU  {DIM}(paste text to summarize, /reset, /exit, Ctrl+C stops an answer){RESET}\n")
    messages = []
    while True:
        try:
            prompt = input(PROMPT).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not prompt:
            continue
        if prompt in ("/exit", "/quit"):
            return
        if prompt == "/reset":
            messages = []
            print(f"{DIM}conversation cleared{RESET}\n")
            continue

        messages.append({"role": "user", "content": prompt})
        answer, usage, in_thinking = [], None, False
        print(f"{BOLD}{model} ›{RESET} ", end="", flush=True)
        try:
            for chunk in stream(url, model, messages, think):
                usage = chunk.get("usage") or usage
                for choice in chunk.get("choices", []):
                    delta = choice.get("delta", {})
                    thought = delta.get("reasoning_content")
                    if thought:
                        if not in_thinking:
                            print(DIM, end="")
                            in_thinking = True
                        print(thought, end="", flush=True)
                    text = delta.get("content")
                    if text:
                        if in_thinking:
                            print(RESET + "\n", end="")
                            in_thinking = False
                        answer.append(text)
                        print(text, end="", flush=True)
        except KeyboardInterrupt:
            print(f"{RESET}\n{DIM}(stopped){RESET}")
        except OSError as error:
            print(f"{RESET}\n{DIM}request failed: {error}{RESET}")
            messages.pop()
            print()
            continue
        print(RESET)
        messages.append({"role": "assistant", "content": "".join(answer)})
        if usage and usage.get("decoding_speed_tps"):
            print(f"{DIM}{usage['decoding_speed_tps']:.1f} tok/s · {usage.get('completion_tokens', '?')} tokens{RESET}")
        print()


if __name__ == "__main__":
    main()
