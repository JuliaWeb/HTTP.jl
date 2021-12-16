"""
Simple server in Julia and client code in JS.

### Example client code (JS):
```http
<html>
<head>
    <meta charset="UTF-8">
    <title>Squaring numbers</title>
</head>
<body>
    <input id="number" placeholder="Input a number" type="number">
    <button id="submit">Square</button>
    <h4>Outputs</h4>
    <ul id="list"></ul>
</body>
<script>
    document.getElementById('submit').addEventListener('click', async function (event) {
        const list = document.getElementById('list');
        try {
            const r = await fetch('http://127.0.0.1:8080/api/square', {
                method: 'POST',
                body: document.getElementById('number').value
            });

            if (r.ok) {
                const body = await r.text()
                const newElement = document.createElement('li');
                newElement.textContent = body;
                list.insertBefore(newElement, list.firstChild);
            } else {
                console.error(r)
            };
        } catch (err) {
            console.error(err)
        }
    })
</script>
</html>
```

### Server code:
"""
using HTTP, JSON

const ROUTER = HTTP.Router()

function square(req::HTTP.Request)
    headers = [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "POST, OPTIONS"
    ]
    # handle CORS requests
    if HTTP.method(req) == "OPTIONS"
        return HTTP.Response(200, headers)
    end
    body = parse(Float64, String(HTTP.body(req)))
    square = body^2
    HTTP.Response(200, headers; body = string(square))
end

HTTP.@register(ROUTER, "POST", "/api/square", square)

HTTP.serve(ROUTER, "127.0.0.1", 8080)
