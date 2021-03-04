"""
A simple example of creating a persistent session and logging into a web form. HTTP.jl does not have a distinct session object like requests.session() or rvest::html_session() but rather uses the `cookies` flag along with standard functions
"""
using HTTP

#dummy site, any credentials work
url = "http://quotes.toscrape.com/login"
session = HTTP.get(url; cookies = true)

credentials = Dict(
    "Username" => "username",
    "Password" => "password")

response = HTTP.post(url, credentials)
