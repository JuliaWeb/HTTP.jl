#TODO:
 # readcookies for requests for server
 # "show" for Cookie for responses (all the attribute fields)

# A Cookie represents an HTTP cookie as sent in the Set-Cookie header of an
# HTTP response or the Cookie header of an HTTP request.
#
# See http:#tools.ietf.org/html/rfc6265 for details.
type Cookie
	name::String
	value::String

	path::String      # optional
	domain::String    # optional
	expires::Nullable{DateTime} # optional

	# MaxAge=0 means no 'Max-Age' attribute specified.
	# MaxAge<0 means delete cookie now, equivalently 'Max-Age: 0'
	# MaxAge>0 means Max-Age attribute present and given in seconds
	maxage::Int
	secure::Bool
	httponly::Bool
    hostonly::Bool
	unparsed::Vector{String} # Raw text of unparsed attribute-value pairs
end

Cookie(name, value) = Cookie(name, value, "", "", Nullable(), 0, false, false, false, String[])

validcookiepathbyte(b) = (' ' <= b < '\x7f') && b != ';'
validcookievaluebyte(b) = (' ' <= b < '\x7f') && b != '"' && b != ';' && b != '\\'

function parsecookievalue(raw, allowdoublequote::Bool)
    if allowdoublequote && length(raw) > 1 && raw[1] == '"' && raw[end] == '"'
        raw = raw[2:end-1]
    end
    for i = 1:length(raw)
        !validcookievaluebyte(raw[i]) && return "", false
    end
    return raw, true
end

iscookienamevalid(raw) = raw == "" ? false : any(is_url_char, raw)

# readSetCookies parses all "Set-Cookie" values from
# the header h and returns the successfully parsed Cookies.
function readsetcookies(host, cookiestrings::Vector{String})
    count = length(cookiestrings)
    count == 0 && return Cookie[]
    cookies = Vector{Cookie}(count)
    for (i, cookie) in enumerate(cookiestrings)
        parts = split(strip(cookie), ';')
        length(parts) == 1 && parts[1] == "" && continue
        parts[1] = strip(parts[1])
        j = findfirst(parts[1], '=')
        j < 1 && continue
        name, value = parts[1][1:j-1], parts[1][j+1:end]
        iscookienamevalid(name) || continue
        value, ok = parsecookievalue(value, true)
        ok || continue
        c = Cookie(name, value)
        for x = 2:length(parts)
            parts[x] = strip(parts[x])
            length(parts[x]) == 0 && continue
            attr, val = parts[x], ""
            j = findfirst(parts[x], '=')
            if j > 0
                attr, val = attr[1:j-1], attr[j+1:end]
            end
            lowerattr = lowercase(attr)
            val, ok = parsecookievalue(val, false)
            if !ok
                push!(c.unparsed, parts[x])
                continue
            end
            if lowerattr == "secure"
                c.secure = true
            elseif lowerattr == "httponly"
                c.httponly = true
            elseif lowerattr == "domain"
                c.domain = val
            elseif lowerattr == "max-age"
                secs = tryparse(Int, val)
                (isnull(secs) || val[1] == '0') && continue
                c.maxage = max(Base.get(secs), -1)
            elseif lowerattr == "expires"
                try
                    c.expires = DateTime(val, Dates.RFC1123Format)
                catch
                    continue
                end
            elseif lowerattr == "path"
                c.path = val
            else
                push!(c.unparsed, parts[x])
            end
        end
        c.domain, c.hostonly = domainandtype(host, c.domain)
        cookies[i] = c
    end
    return cookies
end

# shouldsend determines whether e's cookie qualifies to be included in a
# request to host/path. It is the caller's responsibility to check if the
# cookie is expired.
function shouldsend(cookie::Cookie, https::Bool, host, path)
	return domainmatch(cookie, host) && pathmatch(cookie, path) && (https || !cookie.secure)
end

# domainMatch implements "domain-match" of RFC 6265 section 5.1.3.
function domainmatch(cookie::Cookie, host)
	cookie.domain == host && return true
	return !cookie.hostonly && hasdotsuffix(host, cookie.domain)
end

# hasdotsuffix reports whether s ends in "."+suffix.
function hasdotsuffix(s, suffix)
	return length(s) > length(suffix) && s[length(s)-length(suffix)] == '.' && s[length(s)-length(suffix)+1:end] == suffix
end

# pathMatch implements "path-match" according to RFC 6265 section 5.1.4.
function pathmatch(cookie::Cookie, requestpath)
    requestpath == cookie.path && return true
    if startswith(requestpath, cookie.path)
        if cookie.path[end] == '/'
            return true # The "/any/" matches "/any/path" case.
        elseif requestpath[length(cookie.path)] == '/'
            return true # The "/any" matches "/any/path" case.
        end
	end
	return false
end

function isIP(host)
    try
        parse(IPAddr, host)
        return true
    catch
        return false
    end
end

# domainAndType determines the cookie's domain and hostOnly attribute.
function domainandtype(host, domain)
	if domain == ""
		# No domain attribute in the SetCookie header indicates a
		# host cookie.
		return host, true
	end

	if isIP(host)
		# According to RFC 6265 domain-matching includes not being
		# an IP address.
		# TODO: This might be relaxed as in common browsers.
		return "", false
	end

	# From here on: If the cookie is valid, it is a domain cookie (with
	# the one exception of a public suffix below).
	# See RFC 6265 section 5.2.3.
	if domain[1] == '.'
		domain = domain[2:end]
	end

	if length(domain) == 0 || domain[1] == '.'
		# Received either "Domain=." or "Domain=..some.thing",
		# both are illegal.
		return "", false
	end
	domain = lowercase(domain)

	if domain[end] == '.'
		# We received stuff like "Domain=www.example.com.".
		# Browsers do handle such stuff (actually differently) but
		# RFC 6265 seems to be clear here (e.g. section 4.1.2.3) in
		# requiring a reject.  4.1.2.3 is not normative, but
		# "Domain Matching" (5.1.3) and "Canonicalized Host Names"
		# (5.1.2) are.
		return "", false
	end

    #TODO:
	# See RFC 6265 section 5.3 #5.
	# if j.psList != nil
	# 	if ps := j.psList.PublicSuffix(domain); ps != "" && !hasDotSuffix(domain, ps)
	# 		if host == domain
	# 			# This is the one exception in which a cookie
	# 			# with a domain attribute is a host cookie.
	# 			return host, true, nil
	# 		end
	# 		return "", false
	# 	end
	# end

	# The domain must domain-match host: www.mycompany.com cannot
	# set cookies for .ourcompetitors.com.
	if host != domain && !hasdotsuffix(host, domain)
		return "", false
	end

	return domain, false
end

# request cookie stringify-ing
function Base.string(cookiestring::String, cookies::Cookie...)
    io = IOBuffer()
    !isempty(cookiestring) && write(io, cookiestring, cookiestring[end] == ';' ? "" : ";")
    for cookie in cookies
        write(io, cookie.name, '=', cookie.value, ';')
    end
    return takebuf_string(io)
end

# function (c *Cookie) String() String {
# 	if c == nil || !isCookieNameValid(c.Name) {
# 		return ""
# 	}
# 	var b bytes.Buffer
# 	b.WriteString(sanitizeCookieName(c.Name))
# 	b.WriteRune('=')
# 	b.WriteString(sanitizeCookieValue(c.Value))


# readCookies parses all "Cookie" values from the header h and
# returns the successfully parsed Cookies.
#
# if filter isn't empty, only cookies of that name are returned
# function readCookies(h Header, filter String) []*Cookie {
# 	lines, ok := h["Cookie"]
# 	if !ok {
# 		return []*Cookie{}
# 	}
#
# 	cookies := []*Cookie{}
# 	for _, line := range lines {
# 		parts := Strings.Split(Strings.TrimSpace(line), ";")
# 		if len(parts) == 1 && parts[0] == "" {
# 			continue
# 		}
# 		# Per-line attributes
# 		parsedPairs := 0
# 		for i := 0; i < len(parts); i++ {
# 			parts[i] = Strings.TrimSpace(parts[i])
# 			if len(parts[i]) == 0 {
# 				continue
# 			}
# 			name, val := parts[i], ""
# 			if j := Strings.Index(name, "="); j >= 0 {
# 				name, val = name[:j], name[j+1:]
# 			}
# 			if !isCookieNameValid(name) {
# 				continue
# 			}
# 			if filter != "" && filter != name {
# 				continue
# 			}
# 			val, ok := parseCookieValue(val, true)
# 			if !ok {
# 				continue
# 			}
# 			cookies = append(cookies, &Cookie{Name: name, Value: val})
# 			parsedPairs++
# 		}
# 	}
# 	return cookies
# }
#
# # SetCookie adds a Set-Cookie header to the provided ResponseWriter's headers.
# # The provided cookie must have a valid Name. Invalid cookies may be
# # silently dropped.
# function SetCookie(w ResponseWriter, cookie *Cookie) {
# 	if v := cookie.String(); v != "" {
# 		w.Header().Add("Set-Cookie", v)
# 	}
# }
#
# # String returns the serialization of the cookie for use in a Cookie
# # header (if only Name and Value are set) or a Set-Cookie response
# # header (if other fields are set).
# # If c is nil or c.Name is invalid, the empty String is returned.
# function (c *Cookie) String() String {
# 	if c == nil || !isCookieNameValid(c.Name) {
# 		return ""
# 	}
# 	var b bytes.Buffer
# 	b.WriteString(sanitizeCookieName(c.Name))
# 	b.WriteRune('=')
# 	b.WriteString(sanitizeCookieValue(c.Value))
#
# 	if len(c.Path) > 0 {
# 		b.WriteString("; Path=")
# 		b.WriteString(sanitizeCookiePath(c.Path))
# 	}
# 	if len(c.Domain) > 0 {
# 		if validCookieDomain(c.Domain) {
# 			# A c.Domain containing illegal characters is not
# 			# sanitized but simply dropped which turns the cookie
# 			# Into a host-only cookie. A leading dot is okay
# 			# but won't be sent.
# 			d := c.Domain
# 			if d[0] == '.' {
# 				d = d[1:]
# 			}
# 			b.WriteString("; Domain=")
# 			b.WriteString(d)
# 		} else {
# 			log.PrIntf("net/http: invalid Cookie.Domain %q; dropping domain attribute", c.Domain)
# 		}
# 	}
# 	if validCookieExpires(c.Expires) {
# 		b.WriteString("; Expires=")
# 		b2 := b.Bytes()
# 		b.Reset()
# 		b.Write(c.Expires.UTC().AppendFormat(b2, TimeFormat))
# 	}
# 	if c.MaxAge > 0 {
# 		b.WriteString("; Max-Age=")
# 		b2 := b.Bytes()
# 		b.Reset()
# 		b.Write(strconv.AppendInt(b2, Int64(c.MaxAge), 10))
# 	} else if c.MaxAge < 0 {
# 		b.WriteString("; Max-Age=0")
# 	}
# 	if c.HttpOnly {
# 		b.WriteString("; HttpOnly")
# 	}
# 	if c.Secure {
# 		b.WriteString("; Secure")
# 	}
# 	return b.String()
# }
#
# # validCookieDomain returns whether v is a valid cookie domain-value.
# function validCookieDomain(v String) Bool {
# 	if isCookieDomainName(v) {
# 		return true
# 	}
# 	if net.ParseIP(v) != nil && !Strings.Contains(v, ":") {
# 		return true
# 	}
# 	return false
# }
#
# # validCookieExpires returns whether v is a valid cookie expires-value.
# function validCookieExpires(t time.Time) Bool {
# 	# IETF RFC 6265 Section 5.1.1.5, the year must not be less than 1601
# 	return t.Year() >= 1601
# }
#
# # isCookieDomainName returns whether s is a valid domain name or a valid
# # domain name with a leading dot '.'.  It is almost a direct copy of
# # package net's isDomainName.
# function isCookieDomainName(s String) Bool {
# 	if len(s) == 0 {
# 		return false
# 	}
# 	if len(s) > 255 {
# 		return false
# 	}
#
# 	if s[0] == '.' {
# 		# A cookie a domain attribute may start with a leading dot.
# 		s = s[1:]
# 	}
# 	last := byte('.')
# 	ok := false # Ok once we've seen a letter.
# 	partlen := 0
# 	for i := 0; i < len(s); i++ {
# 		c := s[i]
# 		switch {
# 		default:
# 			return false
# 		case 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z':
# 			# No '_' allowed here (in contrast to package net).
# 			ok = true
# 			partlen++
# 		case '0' <= c && c <= '9':
# 			# fine
# 			partlen++
# 		case c == '-':
# 			# Byte before dash cannot be dot.
# 			if last == '.' {
# 				return false
# 			}
# 			partlen++
# 		case c == '.':
# 			# Byte before dot cannot be dot, dash.
# 			if last == '.' || last == '-' {
# 				return false
# 			}
# 			if partlen > 63 || partlen == 0 {
# 				return false
# 			}
# 			partlen = 0
# 		}
# 		last = c
# 	}
# 	if last == '-' || partlen > 63 {
# 		return false
# 	}
#
# 	return ok
# }
#
# var cookieNameSanitizer = Strings.NewReplacer("\n", "-", "\r", "-")
#
# function sanitizeCookieName(n String) String {
# 	return cookieNameSanitizer.Replace(n)
# }
#
# # http:#tools.ietf.org/html/rfc6265#section-4.1.1
# # cookie-value      = *cookie-octet / ( DQUOTE *cookie-octet DQUOTE )
# # cookie-octet      = %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E
# #           ; US-ASCII characters excluding CTLs,
# #           ; whitespace DQUOTE, comma, semicolon,
# #           ; and backslash
# # We loosen this as spaces and commas are common in cookie values
# # but we produce a quoted cookie-value in when value starts or ends
# # with a comma or space.
# # See https:#golang.org/issue/7243 for the discussion.
# function sanitizeCookieValue(v String) String {
# 	v = sanitizeOrWarn("Cookie.Value", validCookieValueByte, v)
# 	if len(v) == 0 {
# 		return v
# 	}
# 	if v[0] == ' ' || v[0] == ',' || v[len(v)-1] == ' ' || v[len(v)-1] == ',' {
# 		return `"` + v + `"`
# 	}
# 	return v
# }
#
# # path-av           = "Path=" path-value
# # path-value        = <any CHAR except CTLs or ";">
# function sanitizeCookiePath(v String) String {
# 	return sanitizeOrWarn("Cookie.Path", validCookiePathByte, v)
# }
#
# function sanitizeOrWarn(fieldName String, valid function(byte) Bool, v String) String {
# 	ok := true
# 	for i := 0; i < len(v); i++ {
# 		if valid(v[i]) {
# 			continue
# 		}
# 		log.PrIntf("net/http: invalid byte %q in %s; dropping invalid bytes", v[i], fieldName)
# 		ok = false
# 		break
# 	}
# 	if ok {
# 		return v
# 	}
# 	buf := make([]byte, 0, len(v))
# 	for i := 0; i < len(v); i++ {
# 		if b := v[i]; valid(b) {
# 			buf = append(buf, b)
# 		}
# 	}
# 	return String(buf)
# }
