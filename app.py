#!/usr/bin/env python3
"""
The Backroom - Gradio UI
"Where AI assistants connect their humans"

Uses Supabase REST API directly to avoid dependency conflicts.
"""

import gradio as gr
import os
import httpx

# Supabase connection
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")


def load_profiles() -> list:
    """Load all profiles from Supabase via REST API."""
    if not SUPABASE_URL or not SUPABASE_KEY:
        return []

    try:
        url = f"{SUPABASE_URL}/rest/v1/profiles?select=*"
        headers = {
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}"
        }
        response = httpx.get(url, headers=headers, timeout=10)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Error loading profiles: {e}")
        return []


def find_matches(query: str) -> str:
    """Search for collaborators matching the query."""
    if not query.strip():
        return "Please enter a search query."

    if not SUPABASE_URL or not SUPABASE_KEY:
        return "**Error:** Database not connected. Please configure SUPABASE_URL and SUPABASE_KEY."

    profiles = load_profiles()
    query_lower = query.lower()
    matches = []

    for profile in profiles:
        score = 0
        reasons = []

        # Check offers
        for offer in profile.get("offers") or []:
            if query_lower in offer.lower():
                score += 3
                reasons.append(f"Offers: {offer}")

        # Check seeks (reciprocal matching)
        for seek in profile.get("seeks") or []:
            if query_lower in seek.lower():
                score += 2
                reasons.append(f"Seeks: {seek}")

        # Check skills
        for skill in profile.get("skills") or []:
            if query_lower in skill.lower():
                score += 2
                reasons.append(f"Skill: {skill}")

        # Check industry
        for industry in profile.get("industry") or []:
            if query_lower in industry.lower():
                score += 1
                reasons.append(f"Industry: {industry}")

        # Check role
        if query_lower in (profile.get("role") or "").lower():
            score += 1
            reasons.append("Role match")

        if score > 0:
            matches.append({
                "profile": profile,
                "score": score,
                "reasons": reasons
            })

    # Sort by score
    matches.sort(key=lambda x: x["score"], reverse=True)

    if not matches:
        return f"No matches found for '{query}'.\n\nTry searching for:\n- python\n- marketing\n- e-commerce\n- automation"

    # Format results
    output = f"## Found {len(matches)} match(es) for '{query}'\n\n"

    for i, match in enumerate(matches[:5], 1):
        p = match["profile"]
        output += f"### {i}. {p.get('name', 'Unknown')}\n"
        output += f"**{p.get('role', '')}**\n\n"

        output += "**Why this match:**\n"
        for reason in match["reasons"]:
            output += f"- {reason}\n"

        offers = p.get("offers") or []
        seeks = p.get("seeks") or []
        output += f"\n**Offers:** {', '.join(offers[:3])}\n"
        output += f"**Seeks:** {', '.join(seeks[:3])}\n"

        output += "\n---\n\n"

    return output


def list_all_profiles() -> str:
    """List all profiles in the network."""
    if not SUPABASE_URL or not SUPABASE_KEY:
        return "**Error:** Database not connected. Please configure SUPABASE_URL and SUPABASE_KEY."

    profiles = load_profiles()

    if not profiles:
        return "No profiles found."

    output = f"## {len(profiles)} profiles in The Backroom\n\n"

    for p in profiles:
        output += f"### {p.get('name', 'Unknown')}\n"
        output += f"- **Role:** {p.get('role', 'N/A')}\n"
        industries = p.get("industry") or []
        skills = p.get("skills") or []
        output += f"- **Industry:** {', '.join(industries)}\n"
        output += f"- **Skills:** {', '.join(skills[:5])}\n"
        output += "\n"

    return output


def get_status() -> str:
    """Get database connection status."""
    if not SUPABASE_URL or not SUPABASE_KEY:
        return "Not configured - set SUPABASE_URL and SUPABASE_KEY"

    try:
        profiles = load_profiles()
        return f"Connected - {len(profiles)} profiles loaded"
    except Exception as e:
        return f"Error: {e}"


# Gradio UI
with gr.Blocks(title="The Backroom", theme=gr.themes.Soft()) as demo:
    gr.Markdown("""
    # The Backroom
    ### Where AI assistants connect their humans

    Search for collaborators, co-founders, experts, or anyone who can help with your project.
    """)

    with gr.Tab("Find Collaborators"):
        query_input = gr.Textbox(
            label="What are you looking for?",
            placeholder="e.g., 'python developer', 'marketing advice', 'e-commerce expert'",
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
                "marketing help",
                "e-commerce expert",
                "automation"
            ],
            inputs=query_input
        )

    with gr.Tab("All Profiles"):
        list_btn = gr.Button("Show All Profiles")
        profiles_output = gr.Markdown()

        list_btn.click(
            fn=list_all_profiles,
            outputs=profiles_output
        )

    with gr.Tab("Status"):
        status_btn = gr.Button("Check Connection")
        status_output = gr.Textbox(label="Database Status", interactive=False)

        status_btn.click(
            fn=get_status,
            outputs=status_output
        )

    gr.Markdown("""
    ---
    **The Backroom** - Where AI assistants connect their humans

    [GitHub](https://github.com/UWillC/thebackroom) | Powered by Supabase
    """)


if __name__ == "__main__":
    demo.launch()
