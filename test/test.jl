using URIParser
using Base.Test

urls = ["hdfs://user:password@hdfshost:9000/root/folder/file.csv",
    "https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag",
    "ftp://ftp.is.co.za/rfc/rfc1808.txt", "http://www.ietf.org/rfc/rfc2396.txt", 
    "ldap://[2001:db8::7]/c=GB?objectClass?one", "mailto:John.Doe@example.com", 
    "news:comp.infosystems.www.servers.unix", "tel:+1-816-555-1212", "telnet://192.0.2.16:80/", 
    "urn:oasis:names:specification:docbook:dtd:xml:4.1.2"]

failed = 0
for url in urls
	if !(string(URI(url)) == url)
		failed += 1
		println("Test failed for ",url)
	end
end

@test URI("hdfs://user:password@hdfshost:9000/root/folder/file.csv") == URI("hdfs","hdfshost",9000,"/root/folder/file.csv","","","user:password")
@test URI("google.com","/some/path") == URI("http://google.com:80/some/path")

exit(failed)