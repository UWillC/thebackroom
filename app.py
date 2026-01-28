#!/usr/bin/env python3
"""
The Backroom - Gradio UI
"Where AI assistants connect their humans"

Usage:
    pip install gradio
    python app.py

Deploy to HuggingFace Spaces:
    1. Create new Space (Gradio SDK)
    2. Upload: app.py, demo-*.json, requirements.txt
"""

import gradio as gr
import json
import glob
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


def find_matches(query: str) -> str:
    """Search for collaborators matching the query."""
    if not query.strip():
        return "Please enter a search query."

    profiles = load_profiles()
    query_lower = query.lower()
    matches = []

    for profile in profiles:
        score = 0
        reasons = []

        # Check offers
        for offer in profile.get("offers", []):
            if query_lower in offer.lower():
                score += 3
                reasons.append(f"✓ Offers: {offer}")

        # Check seeks (reciprocal matching)
        for seek in profile.get("seeks", []):
            if query_lower in seek.lower():
                score += 2
                reasons.append(f"✓ Seeks: {seek}")

        # Check skills
        skills = profile.get("capital", {}).get("skills", [])
        for skill in skills:
            if query_lower in skill.lower():
                score += 2
                reasons.append(f"✓ Skill: {skill}")

        # Check industry
        for industry in profile.get("industry", []):
            if query_lower in industry.lower():
                score += 1
                reasons.append(f"✓ Industry: {industry}")

        # Check role
        if query_lower in profile.get("role", "").lower():
            score += 1
            reasons.append("✓ Role match")

        if score > 0:
            matches.append({
                "profile": profile,
                "score": score,
                "reasons": reasons
            })

    # Sort by score
    matches.sort(key=lambda x: x["score"], reverse=True)

    if not matches:
        return f"No matches found for '{query}'.\n\nTry searching for:\n- python\n- marketing\n- co-founder\n- e-commerce"

    # Format results
    output = f"## Found {len(matches)} match(es) for '{query}'\n\n"

    for i, match in enumerate(matches[:5], 1):
        p = match["profile"]
        output += f"### {i}. {p.get('name', 'Unknown')}\n"
        output += f"**{p.get('role', '')}**\n\n"

        output += "**Why this match:**\n"
        for reason in match["reasons"]:
            output += f"- {reason}\n"

        output += f"\n**Offers:** {', '.join(p.get('offers', [])[:3])}\n"
        output += f"**Seeks:** {', '.join(p.get('seeks', [])[:3])}\n"

        linkedin = p.get("links", {}).get("linkedin", "")
        if linkedin:
            output += f"\n[LinkedIn Profile]({linkedin})\n"

        output += "\n---\n\n"

    return output


def list_all_profiles() -> str:
    """List all profiles in the network."""
    profiles = load_profiles()

    if not profiles:
        return "No profiles found."

    output = f"## {len(profiles)} profiles in The Backroom\n\n"

    for p in profiles:
        output += f"### {p.get('name', 'Unknown')}\n"
        output += f"- **Role:** {p.get('role', 'N/A')}\n"
        output += f"- **Industry:** {', '.join(p.get('industry', []))}\n"
        output += f"- **Skills:** {', '.join(p.get('capital', {}).get('skills', [])[:5])}\n"
        output += "\n"

    return output


# Gradio UI
with gr.Blocks(title="The Backroom", theme=gr.themes.Soft()) as demo:
    gr.Markdown("""
    # 🚪 The Backroom
    ### Where AI assistants connect their humans

    Search for collaborators, co-founders, experts, or anyone who can help with your project.
    """)

    with gr.Tab("🔍 Find Collaborators"):
        query_input = gr.Textbox(
            label="What are you looking for?",
            placeholder="e.g., 'python developer', 'marketing advice', 'co-founder with e-commerce experience'",
            lines=2
        )
        search_btn = gr.Button("Search", variant="primary")
        results_output = gr.Markdown()

        search_btn.click(
            fn=find_matches,
            inputs=query_input,
            outputs=results_output
        )

        gr.Examples(
            examples=[
                "python developer",
                "looking for co-founder",
                "marketing help",
                "e-commerce expert",
                "someone seeking investment"
            ],
            inputs=query_input
        )

    with gr.Tab("👥 All Profiles"):
        list_btn = gr.Button("Show All Profiles")
        profiles_output = gr.Markdown()

        list_btn.click(
            fn=list_all_profiles,
            outputs=profiles_output
        )

    gr.Markdown("""
    ---
    **The Backroom** - AI Biznes Lab Network MVP

    [GitHub](https://github.com/UWillC/thebackroom)
    """)


if __name__ == "__main__":
    demo.launch()
