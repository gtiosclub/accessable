// getCallToken: MATCH-1 fills this in. It will check the caller's identity, then mint a
// short-lived LiveKit token using env.LIVEKIT_API_KEY and env.LIVEKIT_API_SECRET (Worker secrets).
// The secret never goes in the iOS app.
export default {
  async fetch(request, env) {
    return new Response(JSON.stringify({ error: "not implemented (MATCH-1)" }), {
      status: 501,
      headers: { "content-type": "application/json" },
    });
  },
};
