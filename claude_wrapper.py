#!/usr/bin/env python3
"""
Simple wrapper to call Claude Code from Swift app
Usage: python3 claude_wrapper.py "your prompt here"
"""

import sys
from claude_code import ClaudeSDKClient

def main():
    if len(sys.argv) < 2:
        print("Error: No prompt provided", file=sys.stderr)
        sys.exit(1)

    prompt = sys.argv[1]

    try:
        # Create client and execute query
        client = ClaudeSDKClient()
        result = client.query(prompt)

        # Print result to stdout
        print(result)

    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
