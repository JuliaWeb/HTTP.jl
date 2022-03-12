import { assertEquals } from "https://deno.land/std@0.129.0/testing/asserts.ts";

Deno.test("WebSocket client basics", async (t) => {
    // open a connection to our websocket server
    const ws = new WebSocket("ws://localhost:36984/");
    
    /** A promise that resolves when the connection is closed */
    const close_promise = new Promise((r) => {
        ws.addEventListener("close", () => r(null));
    })
    
    /** The list of all received messages */
    const responses: any[] = []
    ws.addEventListener("message", (e) => {
        // console.debug("Message from server!", e.data)
        responses.push(e.data);
    })
    
    // Send some messages to the server
    const to_send = [
        "one", "two", "three"
    ]
    ws.addEventListener("open", () => {
        to_send.forEach(msg => ws.send(msg))
        ws.send("close");
    });
    
    // Wait for the connection to close (because we asked the server to close)
    await close_promise
    
    
    assertEquals(responses, to_send.map(msg => `Hello, ${msg}`))
  });