"""
The Backroom - Message Status Module
"""

from utils import get_supabase, get_supabase_with_auth


def register_tools(mcp):
    """Register status tools with MCP server."""

    @mcp.tool
    def get_message_status(message_id: str, from_profile_id: str) -> dict:
        """
        Get status of a sent message (who read, responded).

        Args:
            message_id: Message UUID
            from_profile_id: Your profile ID (must be sender)

        Returns:
            Status breakdown
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase_with_auth()

            # Verify sender
            msg_check = client.table("room_messages").select("from_profile_id, subject").eq("id", message_id).execute()
            if not msg_check.data or msg_check.data[0]["from_profile_id"] != from_profile_id:
                return {"error": "You can only check status of your own messages."}

            subject = msg_check.data[0]["subject"]

            # Get status
            status = client.rpc("get_message_status", {"p_message_id": message_id}).execute()

            if status.data:
                s = status.data[0] if isinstance(status.data, list) else status.data
                total = s.get("total_recipients", 0)
                responded = s.get("responded_count", 0)
                read = s.get("read_count", 0)
                unread = s.get("unread_count", 0)

                return {
                    "message_id": message_id,
                    "subject": subject,
                    "status": {
                        "total_recipients": total,
                        "responded": responded,
                        "read": read,
                        "unread": unread,
                        "ignored": s.get("ignored_count", 0)
                    },
                    "progress": f"{responded}/{total} responded ({int(responded/total*100) if total > 0 else 0}%)",
                    "summary": f"{responded} responded | {read} read | {unread} unread"
                }

            return {"error": "Status not available"}

        except Exception as e:
            return {"error": f"Error getting status: {e}"}

    @mcp.tool
    def summarize_responses(message_id: str, from_profile_id: str) -> dict:
        """
        Get all responses to a message and aggregate structured data.

        Args:
            message_id: Original message UUID
            from_profile_id: Your profile ID (must be sender)

        Returns:
            Aggregated summary of all responses with structured data
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase_with_auth()

            # Verify sender
            msg_check = client.table("room_messages").select("from_profile_id, subject, template").eq("id", message_id).execute()
            if not msg_check.data or msg_check.data[0]["from_profile_id"] != from_profile_id:
                return {"error": "You can only summarize responses to your own messages."}

            subject = msg_check.data[0]["subject"]
            expected_template = msg_check.data[0].get("template")

            # Get all responses
            responses = client.rpc("get_message_responses", {"p_message_id": message_id}).execute()

            if not responses.data:
                return {
                    "message_id": message_id,
                    "subject": subject,
                    "total_responses": 0,
                    "message": "No responses yet."
                }

            # Process responses
            response_list = []
            aggregated_data = {}
            numeric_sums = {}
            text_values = {}

            for r in responses.data:
                response_list.append({
                    "from": r.get("from_name"),
                    "assistant": r.get("from_assistant"),
                    "body": r.get("body"),
                    "responded_at": r.get("responded_at")
                })

                # Aggregate structured data
                structured = r.get("structured_data")
                if structured and isinstance(structured, dict):
                    for key, value in structured.items():
                        if isinstance(value, (int, float)):
                            # Sum numeric values
                            if key not in numeric_sums:
                                numeric_sums[key] = {"sum": 0, "count": 0, "values": []}
                            numeric_sums[key]["sum"] += value
                            numeric_sums[key]["count"] += 1
                            numeric_sums[key]["values"].append({"from": r.get("from_name"), "value": value})
                        elif isinstance(value, str):
                            # Collect text values
                            if key not in text_values:
                                text_values[key] = []
                            text_values[key].append({"from": r.get("from_name"), "value": value})

            # Build aggregated summary
            for key, data in numeric_sums.items():
                aggregated_data[key] = {
                    "total": data["sum"],
                    "count": data["count"],
                    "average": round(data["sum"] / data["count"], 2) if data["count"] > 0 else 0,
                    "breakdown": data["values"]
                }

            for key, values in text_values.items():
                aggregated_data[key] = {
                    "responses": values
                }

            # Build summary string
            if aggregated_data:
                agg_parts = []
                for k, v in aggregated_data.items():
                    if 'total' in v:
                        agg_parts.append(f"{k}: {v['total']}")
                    elif 'responses' in v:
                        agg_parts.append(f"{k}: {len(v['responses'])} responses")
                summary_text = f"{len(response_list)} responses received. Aggregated: {', '.join(agg_parts)}"
            else:
                summary_text = f"{len(response_list)} responses received. No structured data to aggregate."

            return {
                "message_id": message_id,
                "subject": subject,
                "total_responses": len(response_list),
                "responses": response_list,
                "aggregated": aggregated_data if aggregated_data else None,
                "summary": summary_text
            }

        except Exception as e:
            return {"error": f"Error summarizing responses: {e}"}
