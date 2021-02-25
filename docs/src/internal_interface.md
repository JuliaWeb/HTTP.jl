# Internal Interfaces

## Parser Interface

```@docs
HTTP.Parsers.find_end_of_header
HTTP.Parsers.find_end_of_chunk_size
HTTP.Parsers.find_end_of_trailer
HTTP.Parsers.parse_status_line!
HTTP.Parsers.parse_request_line!
HTTP.Parsers.parse_header_field
HTTP.Parsers.parse_chunk_size
```

## Messages Interface

```@docs
HTTP.Messages.iserror
HTTP.Messages.isredirect
HTTP.Messages.ischunked
HTTP.Messages.issafe
HTTP.Messages.isidempotent
HTTP.Messages.header
HTTP.Messages.hasheader
HTTP.Messages.setheader
HTTP.Messages.defaultheader!
HTTP.Messages.appendheader
HTTP.Messages.readheaders
HTTP.MessageRequest.setuseragent!
HTTP.Messages.readchunksize
HTTP.Messages.headerscomplete(::HTTP.Messages.Response)
HTTP.Messages.writestartline
HTTP.Messages.writeheaders
Base.write(::IO,::HTTP.Messages.Message)
```

## IOExtras Interface

```@docs
HTTP.IOExtras
HTTP.IOExtras.startwrite(::IO)
HTTP.IOExtras.isioerror
```


## Streams Interface

```@docs
HTTP.Streams.closebody
HTTP.Streams.isaborted
```


## Connection Pooling Interface

```@docs
HTTP.ConnectionPool.Connection
HTTP.ConnectionPool.Transaction
HTTP.ConnectionPool.getconnection
HTTP.ConnectionPool.POOL
HTTP.IOExtras.startwrite(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.closewrite(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.startread(::HTTP.ConnectionPool.Transaction)
HTTP.IOExtras.closeread(::HTTP.ConnectionPool.Transaction)
```
