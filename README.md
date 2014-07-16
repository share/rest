# Livedb REST Frontend

This repository provides a simple REST API for livedb via an express router.

For example:

```javascript
var app = require('express')();

// Create a livedb instance as usual
var db = require('livedb-mongo')('localhost:27017/test?auto_reconnect', {safe:true});
var backend = require('livedb').client(db);

// Then mount the livedb-rest API as an express middleware:
app.use('/shareDocs', require('livedb-rest')(backend));
```

Then `GET /shareDocs/users/fred` will fetch the `fred` document in the `users` collection.


# Exposed methods

The REST middleware exposes the following API endpoints:

### Fetch document - GET & HEAD /:collection/:doc

Get the named document. The body of the result contains the document itself.

- If the document snapshot is a string (text document or JSON document with a string as the body), the document will be returned as the body of the result and `Content-Type: text/plain`
- If the document is not a string, the body is JSON-encoded and returned with `Content-Type: application/json`

The response also sets `X-OT-Version` and `X-OT-Type`.

The server will return 404 if the document doesn't exist (it doesn't have a type set). In this case, `X-OT-Version` is still set but `X-OT-Type` is not.

If you just want to know the version and type, you can send a HEAD request instead of GET.


Eg:

Here I GET a text document. Note the content type is `text/plain` and the OT type is specified in the response:

```bash
$ curl -i 'http://localhost:7007/doc/users/seph'
HTTP/1.1 200 OK
X-OT-Version: 37
X-OT-Type: http://sharejs.org/types/textv1
Content-Type: text/plain
Date: Wed, 21 Aug 2013 00:31:56 GMT
Connection: keep-alive
Transfer-Encoding: chunked

sfdawef
awfe
e
```

Or a JSON document:

```bash
$ curl -i 'http://localhost:7007/doc/users/blah'
HTTP/1.1 200 OK
X-OT-Version: 4
X-OT-Type: http://sharejs.org/types/JSONv0
Content-Type: application/json
Date: Wed, 21 Aug 2013 00:32:54 GMT
Connection: keep-alive
Transfer-Encoding: chunked

{"x":5}
```

### Get ops - GET /:collection/:doc/ops?from:FROM&to:TO

Get the operations for the specified document. This returns all operations from versions [FROM,TO). They should both be non-negative numbers. FROM defaults to 0 if not specified. If TO is not specified, all operations from FROM are returned.

The operations are returned as a JSON list.

Eg:

Get all ops in a document:
```bash
$ curl 'http://localhost:7007/doc/users/seph/ops'
[{"src":"1eb7e54df470511c5252f3c26b90b718","seq":1,"create":{"type":"http://sharejs.org/types/textv1","data":null},"v":0},
{"src":"1eb7e54df470511c5252f3c26b90b718","seq":2,"op":["a"],"v":1},
{"src":"1eb7e54df470511c5252f3c26b90b718","seq":3,"op":[1,"s"],"v":2},
{"src":"1eb7e54df470511c5252f3c26b90b718","seq":4,"op":[2,"d"],"v":3},
{"src":"1eb7e54df470511c5252f3c26b90b718","seq":5,"op":[3,"f"],"v":4}]
```

Or you can get just a few operations:
```bash
$ curl 'http://localhost:7007/doc/users/seph/ops?from=1&to=3'
[{"src":"1eb7e54df470511c5252f3c26b90b718","seq":2,"op":["a"],"v":1},
{"src":"1eb7e54df470511c5252f3c26b90b718","seq":3,"op":[1,"s"],"v":2}]
```

The version numbers are provided for convenience - they can always be inferred from your request. You should probably ignore the src and seq numbers - together they uniquely globally identify an operation.


### Submit Operations - POST /:collection/:doc {v:10, op:['hi']}

You can submit an operation to a document by POST-ing the operation to the document endpoint. The object you post is an opData object. Op data is a JSON object with the following fields:

- **v**: Version of the document to submit against. This should be as recent as possible. The version field is optional to make creating documents easier, but you should almost always include it. If not specified, the version defaults to the current version of the document when the operation reaches the backend.
- **create**: A create operation. This is used to set the type of a document (which creates it). If specified, the value should contain `{type:<TYPE URI>, data:<INITIAL DATA>}`. Initial data is optional.
- **op**: The operation itself. This operation format must match the document's type, and the document must exist. For example, an operation to delete characters 10-30 in a text document would be `[10, {d:20}]`. See the documentation on the type you're using for specifics. [JSON operations are described here](https://github.com/share/ShareJS/wiki/JSON-Operations).
- **del**: Delete the document, which unsets the document's type. The value should be `true`.

Your operation should only contain one of the create/op/del fields. If you don't specify any, your operation will be a no-op, bumping the version but having no effect on the document.

The server will respond with a JSON list containing all operations by which your operation was transformed, if any. It will also have the `X-OT-Version` header set containing the *applied version*, which is the version at which your operation was applied.

You will usually submit operations at the current document version (so, if the document is version 100, you submit an operation with v:100). And normally, the server will apply at the specified version and return an empty list. If someone else's operation reaches the server before yours does, your operation will be transformed by theirs, the applied version will be increased and their operation(s) are returned in the reply. See below for an example of this happening.


### Create a document - PUT /:collection/:doc {type:TYPE, data:INITIAL DATA}

You can simply PUT a document to create it if it doesn't already exist. PUT {...} is a shorthand for POST `{create:{...}}`. The version is not specified in the operation.

The response will usually be 200 OK, and it will contain applied version through the `X-OT-Version: X` header.


### Delete a document - DELETE /:collection/:doc

You can delete a document by simply issuing a RESTful DELETE command. Deleting a document does not delete any of the document's operations - it simply sets the type to null in the backend and removes the document's snapshot. The document can be recreated after its been deleted just like any document that doesn't really exist.

Just like other operations, a delete operation increments the version number.

The response will usually be 200 OK, and it will contain applied version through the `X-OT-Version: X` header.


#### Example


First we create a JSON document on the server:

```bash
$ curl -X PUT -d '{"type":"http://sharejs.org/types/textv1","data":"hi there\n"}' 'http://localhost:7007/doc/users/jeremy'
OK
```

This is equivalent to:

```bash
$ curl -X POST -d '{"create":"type":"http://sharejs.org/types/textv1","data":"hi there"}}'
[]
```

The document now exists:

```bash
$ curl -i 'http://localhost:7007/doc/users/jeremy'
HTTP/1.1 200 OK
X-OT-Version: 1
X-OT-Type: http://sharejs.org/types/textv1
Content-Type: text/plain
Date: Wed, 21 Aug 2013 19:19:35 GMT
Connection: keep-alive
Transfer-Encoding: chunked

hi there
```

Note the version (1) and the type in the headers.

We can edit the document:

```bash
$ curl -i -X POST -d '{"v":1,"op":[8, " everyone!"]}' 'http://localhost:7007/doc/users/jeremy'
HTTP/1.1 200 OK
X-OT-Version: 1
Content-Type: application/json
Date: Wed, 21 Aug 2013 19:43:13 GMT
Connection: keep-alive
Transfer-Encoding: chunked

[]

$ curl 'http://localhost:7007/doc/users/jeremy'
hi there everyone!
```

Note that the *applied version* is 1 (it matches the document version *before* the operation was applied). If we checked the document version now it would be 2.

Another user tried to edit the document at the same time (version 1), inserting text after the newline character:

```bash
$ curl -i -X POST -d '{"v":1,"op":[9, "Oh crap - not another Jabberwocky\n"]}' 'http://localhost:7007/doc/users/jeremy'
HTTP/1.1 200 OK
X-OT-Version: 2
Content-Type: application/json
Date: Wed, 21 Aug 2013 19:51:51 GMT
Connection: keep-alive
Transfer-Encoding: chunked

[{"op":[8," everyone!"],"v":1}]

$ curl 'http://localhost:7007/doc/users/jeremy'
hi there everyone!
Oh crap - not another Jabberwocky
```

Their operation was transformed by ours, and appears where they intended. Their applied version was 2, not 1, and the operation their op was transformed by is returned in the response. The version of the document is now 3.

Finally, we can delete the document:

```bash
$ curl -X DELETE 'http://localhost:7007/doc/users/jeremy'
OK
```

The delete also bumps the document version, which we can see in the `X-OT-Version` header via a GET:

```bash
$ curl -i 'http://localhost:7007/doc/users/jeremy'
HTTP/1.1 404 Not Found
X-OT-Version: 4
Content-Type: text/plain
Date: Wed, 21 Aug 2013 19:58:25 GMT
Connection: keep-alive
Transfer-Encoding: chunked

Document does not exist
```





---

# License

> Standard ISC License

Copyright (c) 2011-2014, Joseph Gentle, Jeremy Apthorp

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.


