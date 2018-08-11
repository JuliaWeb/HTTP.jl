using Base64
import Dates

using Sockets

sprintcompact(x) = sprint(show, x; context=:compact => true)

