"""
This module provides HTTP status code constatnts and related functions 
"""
module StatusCodes

export statustext

# Status code definitions
const CONTINUE =                                                     100
const SWITCHING_PROTOCOLS =                                          101
const PROCESSING =                                                   102
const EARLY_HINTS =                                                  103
const OK =                                                           200
const CREATED =                                                      201
const ACCEPTED =                                                     202
const NON_AUTHORITATIVE_INFORMATION =                                203
const NO_CONTENT =                                                   204
const RESET_CONTENT =                                                205
const PARTIAL_CONTENT =                                              206
const MULTI_STATUS =                                                 207
const ALREADY_REPORTED =                                             208
const IM_USED =                                                      226
const MULTIPLE_CHOICES =                                             300
const MOVED_PERMANENTLY =                                            301
const MOVED_TEMPORARILY =                                            302
const SEE_OTHER =                                                    303
const NOT_MODIFIED =                                                 304
const USE_PROXY =                                                    305
const TEMPORARY_REDIRECT =                                           307
const PERMANENT_REDIRECT =                                           308
const BAD_REQUEST =                                                  400
const UNAUTHORIZED =                                                 401
const PAYMENT_REQUIRED =                                             402
const FORBIDDEN =                                                    403
const NOT_FOUND =                                                    404
const METHOD_NOT_ALLOWED =                                           405
const NOT_ACCEPTABLE =                                               406
const PROXY_AUTHENTICATION_REQUIRED =                                407
const REQUEST_TIME_OUT =                                             408
const CONFLICT =                                                     409
const GONE =                                                         410
const LENGTH_REQUIRED =                                              411
const PRECONDITION_FAILED =                                          412
const REQUEST_ENTITY_TOO_LARGE =                                     413
const REQUEST_URI_TOO_LARGE =                                        414
const UNSUPPORTED_MEDIA_TYPE =                                       415
const REQUESTED_RANGE_NOT_SATISFIABLE =                              416
const EXPECTATION_FAILED =                                           417
const IM_A_TEAPOT =                                                  418
const MISDIRECTED_REQUEST =                                          421
const UNPROCESSABLE_ENTITY =                                         422
const LOCKED =                                                       423
const FAILED_DEPENDENCY =                                            424
const UNORDERED_COLLECTION =                                         425
const UPGRADE_REQUIRED =                                             426
const PRECONDITION_REQUIRED =                                        428
const TOO_MANY_REQUESTS =                                            429
const REQUEST_HEADER_FIELDS_TOO_LARGE =                              431
const LOGIN_TIMEOUT =                                                440
const NGINX_ERROR_NO_RESPONSE =                                      444
const UNAVAILABLE_FOR_LEGAL_REASONS =                                451
const NGINX_ERROR_SSL_CERTIFICATE_ERROR =                            495
const NGINX_ERROR_SSL_CERTIFICATE_REQUIRED =                         496
const NGINX_ERROR_HTTP_TO_HTTPS =                                    497
const NGINX_ERROR_OR_ANTIVIRUS_INTERCEPTED_REQUEST_OR_ARCGIS_ERROR = 499
const INTERNAL_SERVER_ERROR =                                        500
const NOT_IMPLEMENTED =                                              501
const BAD_GATEWAY =                                                  502
const SERVICE_UNAVAILABLE =                                          503
const GATEWAY_TIME_OUT =                                             504
const HTTP_VERSION_NOT_SUPPORTED =                                   505
const VARIANT_ALSO_NEGOTIATES =                                      506
const INSUFFICIENT_STORAGE =                                         507
const LOOP_DETECTED =                                                508
const BANDWIDTH_LIMIT_EXCEEDED =                                     509
const NOT_EXTENDED =                                                 510
const NETWORK_AUTHENTICATION_REQUIRED =                              511
const CLOUDFLARE_SERVER_ERROR_UNKNOWN =                              520
const CLOUDFLARE_SERVER_ERROR_CONNECTION_REFUSED =                   521
const CLOUDFLARE_SERVER_ERROR_CONNECTION_TIMEOUT =                   522
const CLOUDFLARE_SERVER_ERROR_ORIGIN_SERVER_UNREACHABLE =            523
const CLOUDFLARE_SERVER_ERROR_A_TIMEOUT =                            524
const CLOUDFLARE_SERVER_ERROR_CONNECTION_FAILED =                    525
const CLOUDFLARE_SERVER_ERROR_INVALID_SSL_CERITIFICATE =             526
const CLOUDFLARE_SERVER_ERROR_RAILGUN_ERROR =                        527
const SITE_FROZEN =                                                  530

include("status_messages.jl")

end # module StatusCodes
