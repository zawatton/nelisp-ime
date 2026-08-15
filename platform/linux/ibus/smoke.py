from nelisp_client import NeLispClient

client = NeLispClient()
try:
    session = "ibus-smoke"
    client.request("ime/session.open", {"sessionId": session, "inputStyle": "romaji"})
    result = None
    for key in "kanji":
        result = client.request("ime/session.feed",
                                {"sessionId": session,
                                 "event": {"op": "key", "key": key}})
    assert result["reading"] == "かんじ"
    assert result["preedit"] == "漢字"
finally:
    client.close()
