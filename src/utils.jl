##
# Splits the userinfo portion of an URI in the format user:password and 
# returns the components as tuple.
#
# Note: This is just a convenience method, and this form of usage is 
# deprecated as of rfc3986.
# See: http://tools.ietf.org/html/rfc3986#section-3.2.1
function userinfo(uri::URI)
    Base.warn_once("Use of the format user:password is deprecated (rfc3986)")
    uinfo = uri.userinfo
    sep = search(uinfo, ':')
    l = length(uinfo)
    username = uinfo[1:(sep-1)]
    password = ((sep == l) || (sep == 0)) ? "" : uinfo[(sep+1):l]
    (username, password)
end

##
# Splits the path into components and parameters
# See: http://tools.ietf.org/html/rfc3986#section-3.3
function path_params(uri::URI, seps=[';',',','='])
    elems = split(uri.path, '/', false)
    p = Array[]
    for elem in elems
        pp = split(elem, seps)
        push!(p, pp)
    end
    p
end

##
# Create equivalent URI without the fragment
defrag(uri::URI) = URI(uri.schema, uri.host, uri.port, uri.path, uri.query, "", uri.userinfo, uri.specifies_authority)

##
# Validate known URI formats
const uses_authority = ["hdfs", "ftp", "http", "gopher", "nntp", "telnet", "imap", "wais", "file", "mms", "https", "shttp", "snews", "prospero", "rtsp", "rtspu", "rsync", "svn", "svn+ssh", "sftp" ,"nfs", "git", "git+ssh", "ldap"]
const uses_params = ["ftp", "hdl", "prospero", "http", "imap", "https", "shttp", "rtsp", "rtspu", "sip", "sips", "mms", "sftp", "tel"]
const non_hierarchical = ["gopher", "hdl", "mailto", "news", "telnet", "wais", "imap", "snews", "sip", "sips"]
const uses_query = ["http", "wais", "imap", "https", "shttp", "mms", "gopher", "rtsp", "rtspu", "sip", "sips", "ldap"]
const uses_fragment = ["hdfs", "ftp", "hdl", "http", "gopher", "news", "nntp", "wais", "https", "shttp", "snews", "file", "prospero"]

function isvalid(uri::URI)
    schema = uri.schema
    isempty(schema) && error("Can not validate relative URI")
    if ((schema in non_hierarchical) && (search(uri.path, '/') > 1)) ||       # path hierarchy not allowed
       (!(schema in uses_query) && !isempty(uri.query)) ||                    # query component not allowed 
       (!(schema in uses_fragment) && !isempty(uri.fragment)) ||              # fragment identifier component not allowed
       (!(schema in uses_authority) && (!isempty(uri.host) || (0 != uri.port) || !isempty(uri.userinfo))) # authority component not allowed
        return false
    end
    true
end


