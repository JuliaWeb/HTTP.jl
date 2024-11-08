import { assertEquals } from "https://deno.land/std@0.129.0/testing/asserts.ts";

Deno.test("WebSocket client basics", async (t) => {
    // open a connection to our websocket server
    const ws = new WebSocket("ws://localhost:36984/");
    
    /** A promise that resolves when the connection is closed */
    const close_promise = new Promise((r) => {
        ws.addEventListener("close", () => {
            // short grace period
            setTimeout(() => r(null), 250);
        });
    })
    
    /** The list of all received messages */
    const client_received_messages: any[] = []
    ws.addEventListener("message", (e) => {
        // console.debug("Message from server!", e.data)
        client_received_messages.push(e.data);
    })
    
    // Send some messages to the server
    const to_send = [
        "world" //, "two", "three"
    ]
    ws.addEventListener("open", () => {
        to_send.forEach(msg => ws.send(msg))
        ws.send("close");
    });
    
    // Wait for the connection to close (because we asked the server to close)
    await close_promise
    
    
    assertEquals(client_received_messages, to_send.map(msg => `Hello, ${msg}`))
  });