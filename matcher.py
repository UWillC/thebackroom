#!/usr/bin/env python3
"""
AI Biznes Lab Network - Simple Matcher MVP
Przeszukuje profile i znajduje dopasowania.

Użycie:
    python matcher.py "network automation"
    python matcher.py "marketing" --category seeks
"""

import json
import glob
import argparse
from pathlib import Path


def load_profiles(profiles_dir: str = None) -> list:
    """Wczytaj wszystkie profile JSON z katalogu."""
    if profiles_dir is None:
        profiles_dir = Path(__file__).parent

    profiles = []
    for file_path in glob.glob(f"{profiles_dir}/*.json"):
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                profile = json.load(f)
                profile['_file'] = Path(file_path).name
                profiles.append(profile)
        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Could not load {file_path}: {e}")

    return profiles


def search_profiles(
    query: str,
    profiles: list,
    categories: list = None
) -> list:
    """
    Szukaj w profilach.

    Args:
        query: Szukana fraza
        profiles: Lista profili
        categories: Kategorie do przeszukania (domyślnie: offers, seeks, skills)

    Returns:
        Lista dopasowań
    """
    if categories is None:
        categories = ['offers', 'seeks', 'industry', 'capital.skills']

    query_lower = query.lower()
    matches = []

    for profile in profiles:
        profile_matches = []

        for category in categories:
            # Obsługa zagnieżdżonych kluczy (np. capital.skills)
            if '.' in category:
                parts = category.split('.')
                value = profile
                for part in parts:
                    value = value.get(part, {})
            else:
                value = profile.get(category, [])

            # Konwertuj do listy jeśli trzeba
            if isinstance(value, str):
                value = [value]
            elif isinstance(value, dict):
                value = list(value.values())

            # Szukaj dopasowań
            for item in value:
                if isinstance(item, str) and query_lower in item.lower():
                    profile_matches.append({
                        'category': category,
                        'match': item
                    })

        if profile_matches:
            matches.append({
                'name': profile.get('name', 'Unknown'),
                'id': profile.get('id', 'unknown'),
                'role': profile.get('role', ''),
                'linkedin': profile.get('links', {}).get('linkedin', ''),
                'matches': profile_matches
            })

    return matches


def format_results(matches: list) -> str:
    """Formatuj wyniki do wyświetlenia."""
    if not matches:
        return "Brak dopasowań."

    lines = [f"Znaleziono {len(matches)} dopasowań:\n"]

    for i, match in enumerate(matches, 1):
        lines.append(f"{i}. {match['name']}")
        lines.append(f"   Role: {match['role']}")
        lines.append(f"   LinkedIn: {match['linkedin']}")
        lines.append("   Dopasowania:")
        for m in match['matches']:
            lines.append(f"   - [{m['category']}] {m['match']}")
        lines.append("")

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(
        description='AI Biznes Lab Network Matcher'
    )
    parser.add_argument(
        'query',
        help='Szukana fraza'
    )
    parser.add_argument(
        '--category', '-c',
        action='append',
        help='Kategoria do przeszukania (można użyć wielokrotnie)'
    )
    parser.add_argument(
        '--dir', '-d',
        default=None,
        help='Katalog z profilami (domyślnie: katalog skryptu)'
    )
    parser.add_argument(
        '--json', '-j',
        action='store_true',
        help='Wyświetl wyniki jako JSON'
    )

    args = parser.parse_args()

    profiles = load_profiles(args.dir)

    if not profiles:
        print("Nie znaleziono profili!")
        return

    print(f"Załadowano {len(profiles)} profili.\n")

    matches = search_profiles(
        args.query,
        profiles,
        args.category
    )

    if args.json:
        print(json.dumps(matches, indent=2, ensure_ascii=False))
    else:
        print(format_results(matches))


if __name__ == '__main__':
    main()
