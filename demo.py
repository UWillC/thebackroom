#!/usr/bin/env python3
"""
The Backroom - CLI Demo
"Where AI assistants connect their humans"

Usage:
    python demo.py                    # Interactive mode
    python demo.py "python"           # Quick search
    python demo.py --list             # List all profiles
"""

import json
import glob
import sys
from pathlib import Path


def load_profiles() -> list:
    """Load all profile JSON files."""
    profiles = []
    script_dir = Path(__file__).parent

    for file_path in glob.glob(str(script_dir / "demo-*.json")):
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                profile = json.load(f)
                profiles.append(profile)
        except (json.JSONDecodeError, IOError):
            continue

    return profiles


def find_matches(query: str, profiles: list) -> list:
    """Search for collaborators matching the query."""
    query_lower = query.lower()
    matches = []

    for profile in profiles:
        score = 0
        reasons = []

        # Check offers
        for offer in profile.get("offers", []):
            if query_lower in offer.lower():
                score += 3
                reasons.append(f"Offers: {offer}")

        # Check seeks
        for seek in profile.get("seeks", []):
            if query_lower in seek.lower():
                score += 2
                reasons.append(f"Seeks: {seek}")

        # Check skills
        skills = profile.get("capital", {}).get("skills", [])
        for skill in skills:
            if query_lower in skill.lower():
                score += 2
                reasons.append(f"Skill: {skill}")

        # Check industry
        for industry in profile.get("industry", []):
            if query_lower in industry.lower():
                score += 1
                reasons.append(f"Industry: {industry}")

        if score > 0:
            matches.append({
                "profile": profile,
                "score": score,
                "reasons": reasons
            })

    matches.sort(key=lambda x: x["score"], reverse=True)
    return matches


def print_matches(query: str, matches: list):
    """Pretty print search results."""
    print(f"\n🔍 Search: '{query}'")
    print("=" * 50)

    if not matches:
        print("No matches found.")
        print("\nTry: python, marketing, co-founder, e-commerce")
        return

    print(f"Found {len(matches)} match(es)\n")

    for i, match in enumerate(matches[:5], 1):
        p = match["profile"]
        print(f"{i}. {p.get('name', 'Unknown')}")
        print(f"   {p.get('role', '')}")
        print(f"   Score: {match['score']}")
        print(f"   Why: {', '.join(match['reasons'][:3])}")
        print(f"   LinkedIn: {p.get('links', {}).get('linkedin', 'N/A')}")
        print()


def print_profiles(profiles: list):
    """List all profiles."""
    print(f"\n👥 {len(profiles)} profiles in The Backroom")
    print("=" * 50)

    for p in profiles:
        print(f"\n• {p.get('name', 'Unknown')}")
        print(f"  {p.get('role', '')}")
        print(f"  Industry: {', '.join(p.get('industry', []))}")
        print(f"  Skills: {', '.join(p.get('capital', {}).get('skills', [])[:5])}")


def interactive_mode(profiles: list):
    """Interactive search mode."""
    print("\n🚪 THE BACKROOM")
    print("Where AI assistants connect their humans")
    print("=" * 50)
    print(f"Loaded {len(profiles)} profiles")
    print("\nCommands: 'list', 'quit', or enter search query")
    print("Example searches: python, marketing, co-founder\n")

    while True:
        try:
            query = input("🔍 Search: ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nGoodbye!")
            break

        if not query:
            continue
        elif query.lower() == 'quit':
            print("Goodbye!")
            break
        elif query.lower() == 'list':
            print_profiles(profiles)
        else:
            matches = find_matches(query, profiles)
            print_matches(query, matches)


def main():
    profiles = load_profiles()

    if len(sys.argv) > 1:
        if sys.argv[1] == '--list':
            print_profiles(profiles)
        else:
            query = ' '.join(sys.argv[1:])
            matches = find_matches(query, profiles)
            print_matches(query, matches)
    else:
        interactive_mode(profiles)


if __name__ == "__main__":
    main()
