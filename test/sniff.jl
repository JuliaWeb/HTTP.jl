const test_cases = [
    ("Empty", UInt8[], "text/plain; charset=utf-8"),
    ("Binary", UInt8[1, 2, 3], "application/octet-stream"),

    ("HTML document #1", b"<HtMl><bOdY>blah blah blah</body></html>", "text/html; charset=utf-8"),
    ("HTML document #2", b"<HTML></HTML>", "text/html; charset=utf-8"),
    ("HTML document #3 (leading whitespace)", b"   <!DOCTYPE HTML>...", "text/html; charset=utf-8"),
    ("HTML document #4 (leading CRLF)", b"\r\n<html>...", "text/html; charset=utf-8"),

    ("Plain text", b"This is not HTML. It has ☃ though.", "text/plain; charset=utf-8"),

    ("XML", b"\n<?xml!", "text/xml; charset=utf-8"),

    # Image types.
    ("GIF 87a", b"GIF87a", "image/gif"),
    ("GIF 89a", b"GIF89a...", "image/gif"),

    # Audio types.
    ("MIDI audio", UInt8['M','T','h','d',0x00,0x00,0x00,0x06,0x00,0x01], "audio/midi"),
    ("MP3 audio/MPEG audio", UInt8['I','D','3',0x03,0x00,0x00,0x00,0x00,0x0f], "audio/mpeg"),
    ("WAV audio #1", UInt8['R','I','F','F','b',0xb8,0x00,0x00,'W','A','V','E','f','m','t',' ',0x12,0x00,0x00,0x00,0x06], "audio/wave"),
    ("WAV audio #2", UInt8['R','I','F','F',',',0x00,0x00,0x00,'W','A','V','E','f','m','t',' ',0x12,0x00,0x00,0x00,0x06], "audio/wave"),
    ("AIFF audio #1", UInt8['F','O','R','M',0x00,0x00,0x00,0x00,'A','I','F','F','C','O','M','M',0x00,0x00,0x00,0x12,0x00,0x01,0x00,0x00,0x57,0x55,0x00,0x10,0x40,0x0d,0xf3,0x34], "audio/aiff"),
    ("OGG audio", UInt8['O','g','g','S',0x00,0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x7e,0x46,0x00,0x00,0x00,0x00,0x00,0x00,0x1f,0xf6,0xb4,0xfc,0x01,0x1e,0x01,0x76,0x6f,0x72], "application/ogg"),

    # Video types.
    ("MP4 video", UInt8[0x00,0x00,0x00,0x18,'f','t','y','p','m','p','4','2',0x00,0x00,0x00,0x00,'m','p','4','2','i','s','o','m','<',0x06,'t',0xbf,'m','d','a','t'], "video/mp4"),
    ("AVI video #1", UInt8['R','I','F','F',',','O','\n',0x00,'A','V','I',' ','L','I','S','T','À'], "video/avi"),
    ("AVI video #2", UInt8['R','I','F','F',',','\n',0x00,0x00,'A','V','I',' ','L','I','S','T','À'], "video/avi"),
]

@testset "HTTP.sniff" begin
    for case in test_cases
        println("TEST - sniff.jl: ", case[1])
        @test HTTP.sniff(case[2]) == case[3]
    end

    @test HTTP.sniff(IOBuffer(test_cases[1][2])) == HTTP.sniff(test_cases[1][2])
end

json_strings = [
"n",
"nu",
"nul",
"null",
"t",
"tr",
"tru",
"true",
"f",
"fa",
"fal",
"fals",
"false",
"\"sample string \\\" with escaped double quote\"",
"1",
"1.0",
"3.1428",
"100000",
"[1,2,3]",
"[ \"simple array\" , {\"key\": null } ,{ \"key2\"  : false}]",
"{\"simpleobject\": null}",
"""
{
    "glossary": {
        "title": "example glossary",
		"GlossDiv": {
            "title": "S",
			"GlossList": {
                "GlossEntry": {
                    "ID": "SGML",
					"SortAs": "SGML",
					"GlossTerm": "Standard Generalized Markup Language",
					"Acronym": "SGML",
					"Abbrev": "ISO 8879:1986",
					"GlossDef": {
                        "para": "A meta-markup language, used to create markup languages such as DocBook.",
						"GlossSeeAlso": ["GML", "XML"]
                    },
					"GlossSee": "markup"
                }
            }
        }
    }
}
""",
"""
{"menu": {
  "id": "file",
  "value": "File",
  "popup": {
    "menuitem": [
      {"value": "New", "onclick": "CreateNewDoc()"},
      {"value": "Open", "onclick": "OpenDoc()"},
      {"value": "Close", "onclick": "CloseDoc()"}
    ]
  }
}}
""",
"""
{"widget": {
    "debug": "on",
    "window": {
        "title": "Sample Konfabulator Widget",
        "name": "main_window",
        "width": 500,
        "height": 500
    },
    "image": {
        "src": "Images/Sun.png",
        "name": "sun1",
        "hOffset": 250,
        "vOffset": 250,
        "alignment": "center"
    },
    "text": {
        "data": "Click Here",
        "size": 36,
        "style": "bold",
        "name": "text1",
        "hOffset": 250,
        "vOffset": 100,
        "alignment": "center",
        "onMouseUp": "sun1.opacity = (sun1.opacity / 100) * 90;"
    }
}}
""",
"""
{"web-app": {
  "servlet": [
    {
      "servlet-name": "cofaxCDS",
      "servlet-class": "org.cofax.cds.CDSServlet",
      "init-param": {
        "configGlossary:installationAt": "Philadelphia, PA",
        "configGlossary:adminEmail": "ksm@pobox.com",
        "configGlossary:poweredBy": "Cofax",
        "configGlossary:poweredByIcon": "/images/cofax.gif",
        "configGlossary:staticPath": "/content/static",
        "templateProcessorClass": "org.cofax.WysiwygTemplate",
        "templateLoaderClass": "org.cofax.FilesTemplateLoader",
        "templatePath": "templates",
        "templateOverridePath": "",
        "defaultListTemplate": "listTemplate.htm",
        "defaultFileTemplate": "articleTemplate.htm",
        "useJSP": false,
        "jspListTemplate": "listTemplate.jsp",
        "jspFileTemplate": "articleTemplate.jsp",
        "cachePackageTagsTrack": 200,
        "cachePackageTagsStore": 200,
        "cachePackageTagsRefresh": 60,
        "cacheTemplatesTrack": 100,
        "cacheTemplatesStore": 50,
        "cacheTemplatesRefresh": 15,
        "cachePagesTrack": 200,
        "cachePagesStore": 100,
        "cachePagesRefresh": 10,
        "cachePagesDirtyRead": 10,
        "searchEngineListTemplate": "forSearchEnginesList.htm",
        "searchEngineFileTemplate": "forSearchEngines.htm",
        "searchEngineRobotsDb": "WEB-INF/robots.db",
        "useDataStore": true,
        "dataStoreClass": "org.cofax.SqlDataStore",
        "redirectionClass": "org.cofax.SqlRedirection",
        "dataStoreName": "cofax",
        "dataStoreDriver": "com.microsoft.jdbc.sqlserver.SQLServerDriver",
        "dataStoreUrl": "jdbc:microsoft:sqlserver://LOCALHOST:1433;DatabaseName=goon",
        "dataStoreUser": "sa",
        "dataStorePassword": "dataStoreTestQuery",
        "dataStoreTestQuery": "SET NOCOUNT ON;select test='test';",
        "dataStoreLogFile": "/usr/local/tomcat/logs/datastore.log",
        "dataStoreInitConns": 10,
        "dataStoreMaxConns": 100,
        "dataStoreConnUsageLimit": 100,
        "dataStoreLogLevel": "debug",
        "maxUrlLength": 500}},
    {
      "servlet-name": "cofaxEmail",
      "servlet-class": "org.cofax.cds.EmailServlet",
      "init-param": {
      "mailHost": "mail1",
      "mailHostOverride": "mail2"}},
    {
      "servlet-name": "cofaxAdmin",
      "servlet-class": "org.cofax.cds.AdminServlet"},

    {
      "servlet-name": "fileServlet",
      "servlet-class": "org.cofax.cds.FileServlet"},
    {
      "servlet-name": "cofaxTools",
      "servlet-class": "org.cofax.cms.CofaxToolsServlet",
      "init-param": {
        "templatePath": "toolstemplates/",
        "log": 1,
        "logLocation": "/usr/local/tomcat/logs/CofaxTools.log",
        "logMaxSize": "",
        "dataLog": 1,
        "dataLogLocation": "/usr/local/tomcat/logs/dataLog.log",
        "dataLogMaxSize": "",
        "removePageCache": "/content/admin/remove?cache=pages&id=",
        "removeTemplateCache": "/content/admin/remove?cache=templates&id=",
        "fileTransferFolder": "/usr/local/tomcat/webapps/content/fileTransferFolder",
        "lookInContext": 1,
        "adminGroupID": 4,
        "betaServer": true}}],
  "servlet-mapping": {
    "cofaxCDS": "/",
    "cofaxEmail": "/cofaxutil/aemail/*",
    "cofaxAdmin": "/admin/*",
    "fileServlet": "/static/*",
    "cofaxTools": "/tools/*"},

  "taglib": {
    "taglib-uri": "cofax.tld",
    "taglib-location": "/WEB-INF/tlds/cofax.tld"}}}
""",
"""
{"menu": {
    "header": "SVG Viewer",
    "items": [
        {"id": "Open"},
        {"id": "OpenNew", "label": "Open New"},
        null,
        {"id": "ZoomIn", "label": "Zoom In"},
        {"id": "ZoomOut", "label": "Zoom Out"},
        {"id": "OriginalView", "label": "Original View"},
        null,
        {"id": "Quality"},
        {"id": "Pause"},
        {"id": "Mute"},
        null,
        {"id": "Find", "label": "Find..."},
        {"id": "FindAgain", "label": "Find Again"},
        {"id": "Copy"},
        {"id": "CopyAgain", "label": "Copy Again"},
        {"id": "CopySVG", "label": "Copy SVG"},
        {"id": "ViewSVG", "label": "View SVG"},
        {"id": "ViewSource", "label": "View Source"},
        {"id": "SaveAs", "label": "Save As"},
        null,
        {"id": "Help"},
        {"id": "About", "label": "About Adobe CVG Viewer..."}
    ]
}}
"""
]

@testset "HTTP.isjson" begin
    @test !HTTP.isjson("")[1]
    for str in json_strings
        @test HTTP.isjson(Vector{UInt8}(str))[1]
    end
end
