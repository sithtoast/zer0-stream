// End-to-end check that a running chat service enforces channel-scoped tokens.
//
// Uses one real token from the frontend (a channel page you can chat on):
//   document.getElementById("chat-panel").dataset.token
//   document.getElementById("chat-panel").dataset.channelId
//
//   CHAT_TOKEN=... CHANNEL_ID=7 node scripts/scope_check.mjs wss://chat.dev.zer0.tv/socket
//
// Add --send to also post one test message, which checks that the broadcaster
// badge ignores join params. It appears in that channel's chat for everyone.
// Requires `mix deps.get` (for the Phoenix JS client) and Node 22+.
import {Socket} from "../deps/phoenix/priv/static/phoenix.mjs"

const url = process.argv.find(arg => /^wss?:\/\//.test(arg))
const send = process.argv.includes("--send")
const {CHAT_TOKEN: token, CHANNEL_ID: channelId} = process.env

if (!url || !token || !channelId) {
  console.error("usage: CHAT_TOKEN=... CHANNEL_ID=... node scripts/scope_check.mjs <socket-url> [--send]")
  process.exit(2)
}

const results = []
const record = (ok, name, detail) => {
  results.push(ok)
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` (${detail})` : ""}`)
}

// Resolves "connected" or "refused" for a socket with the given token.
function connect(withToken) {
  return new Promise(resolve => {
    const socket = new Socket(url, {transport: WebSocket, params: {token: withToken}, reconnectAfterMs: () => 60_000})
    const timer = setTimeout(() => { socket.disconnect(); resolve({state: "timeout"}) }, 10_000)
    socket.onOpen(() => { clearTimeout(timer); resolve({state: "connected", socket}) })
    socket.onError(() => { clearTimeout(timer); socket.disconnect(); resolve({state: "refused"}) })
    socket.connect()
  })
}

// Resolves {status: "ok"|"error"|"timeout", response, channel}.
function join(socket, topic, params = {}) {
  return new Promise(resolve => {
    const channel = socket.channel(topic, params)
    channel.join()
      .receive("ok", response => resolve({status: "ok", response, channel}))
      .receive("error", response => { channel.leave(); resolve({status: "error", response}) })
      .receive("timeout", () => { channel.leave(); resolve({status: "timeout"}) })
  })
}

function push(channel, event, payload) {
  return new Promise(resolve => {
    channel.push(event, payload)
      .receive("ok", response => resolve({status: "ok", response}))
      .receive("error", response => resolve({status: "error", response}))
      .receive("timeout", () => resolve({status: "timeout"}))
  })
}

const garbled = await connect(token.slice(0, -4) + "AAAA")
record(garbled.state === "refused", "a tampered token is refused", garbled.state)
garbled.socket?.disconnect()

const main = await connect(token)
if (main.state !== "connected") {
  record(false, "the real token connects", `${main.state}; expired (1h), from another environment, or issued by a frontend older than channel-scoped tokens?`)
  process.exit(1)
}
record(true, "the real token connects")

const own = await join(main.socket, `chat:${channelId}`, {broadcaster_id: "spoofed-broadcaster"})
record(own.status === "ok", `joins its own channel chat:${channelId}`, own.status === "ok" ? "" : JSON.stringify(own.response))

const otherId = /^\d+$/.test(channelId) ? String(Number(channelId) + 1000) : `${channelId}-other`
const other = await join(main.socket, `chat:${otherId}`)
record(
  other.status === "error" && other.response?.reason === "unauthorized",
  `is refused on another channel chat:${otherId}`,
  other.status === "ok" ? "JOINED: the service is not enforcing channel scope (old image?)" : JSON.stringify(other.response)
)

if (send && own.status === "ok") {
  // The token says whether this user is the broadcaster; the bogus join param must not change it.
  const sent = await push(own.channel, "message", {body: "chat scope check ✔ (test message)"})
  const badge = sent.response?.is_broadcaster
  record(sent.status === "ok", "posts a message in its own channel", sent.status === "ok" ? `is_broadcaster=${badge}` : JSON.stringify(sent.response))
  console.log("      is_broadcaster should be true only if this token belongs to the channel's broadcaster;")
  console.log("      the join sent broadcaster_id=\"spoofed-broadcaster\", which the service must ignore.")
}

main.socket.disconnect()
const failed = results.filter(ok => !ok).length
console.log(failed ? `\n${failed} check(s) failed` : "\nAll checks passed")
process.exit(failed ? 1 : 0)
