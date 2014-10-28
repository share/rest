# Tests for the REST-ful interface

assert = require 'assert'
http = require 'http'
querystring = require 'querystring'

rest = require './rest.js'

# A bit of variety
otSimple = require('ot-simple').type
otText = require('ot-text').type

express = require 'express'

livedb = require 'livedb'

# Async fetch. Aggregates whole response and sends to callback.
# Callback should be function(response, data) {...}
fetch = (method, port, path, postData, extraHeaders, callback) ->
  if typeof extraHeaders == 'function'
    callback = extraHeaders
    extraHeaders = null

  headers = extraHeaders || {'x-testing': 'booyah'}

  request = http.request {method, path, host: 'localhost', port, headers}, (response) ->
    data = ''
    response.on 'data', (chunk) -> data += chunk
    response.on 'end', ->
      data = data.trim()
      if response.headers['content-type'] == 'application/json'
        data = JSON.parse(data)

      callback response, data, response.headers

  if postData?
    postData = JSON.stringify(postData) if typeof(postData) == 'object'
    request.write postData

  request.end()

writeOps = (db, cName, docName, ops, index = 0, callback) ->
  if typeof index is 'function'
    [index, callback] = [0, index]

  if index >= ops.length
    return callback()

  op = ops[index]
  db.writeOp cName, docName, op, (err) ->
    return callback(err) if err
    # Recurse.
    writeOps db, cName, docName, ops, index+1, callback

# Frontend tests
describe 'rest', ->
  beforeEach (done) ->
    @collection = '__c'
    @doc = '__doc'

    # Tests fill this in to provide expected backend functionality
    @db = livedb.memory()
    @backend = livedb.client @db
    @middleware = require('livedb-middleware') @backend

    useLivedbMongo = false
    if useLivedbMongo
      @db = require('livedb-mongo')('mongodb://localhost:27017/test?auto_reconnect', safe: false)
      @backend = livedb.client @db
      @middleware = require('livedb-middleware') @backend

    app = express()
    app.use '/doc', rest @middleware

    # Used by the connect middleware below.
    app.use (err, req, res, next) ->
      if err.message is 'Forbidden'
        res.send 403, 'Forbidden'
      else
        next err

    @port = 4321
    @server = http.createServer app
    @server.listen @port, done

  afterEach (done) ->
    @server.on 'close', done
    @server.close()

  describe 'GET & HEAD', ->
    it 'returns 404 for nonexistant documents', (done) ->
      fetch 'GET', @port, "/doc/#{@collection}/#{@doc}", null, (res, data, headers) ->
        assert.strictEqual res.statusCode, 404
        assert.strictEqual headers['x-ot-version'], '0'
        assert.equal headers['x-ot-type'], null
        done()
        
    it 'return 404 and empty body when on HEAD on a nonexistant document', (done) ->
      fetch 'HEAD', @port, "/doc/#{@collection}/#{@doc}", null, (res, data, headers) ->
        assert.strictEqual res.statusCode, 404
        assert.strictEqual data, ''
        assert.strictEqual headers['x-ot-version'], '0'
        assert.equal headers['x-ot-type'], null
        done()
    
    it 'returns 200, empty body, version and type when on HEAD on a document', (done) ->
      @db.writeSnapshot 'c', 'd', {v:1, type:otText.uri, data:'hi there'}, =>

        fetch 'HEAD', @port, "/doc/c/d", null, (res, data, headers) ->
          assert.strictEqual res.statusCode, 200
          assert.strictEqual headers['x-ot-version'], '1'
          assert.strictEqual headers['x-ot-type'], otText.uri
          assert.ok headers['etag']
          assert.strictEqual data, ''
          done()
            
    it 'document returns the document snapshot', (done) ->
      @db.writeSnapshot 'c', 'd', {v:1, type:otSimple.uri, data:{str:'Hi'}}, =>

        fetch 'GET', @port, "/doc/c/d", null, (res, data, headers) ->
          assert.strictEqual res.statusCode, 200
          assert.strictEqual headers['x-ot-version'], '1'
          assert.strictEqual headers['x-ot-type'], otSimple.uri
          assert.ok headers['etag']
          assert.strictEqual headers['content-type'], 'application/json'
          assert.deepEqual data, {str:'Hi'}
          done()

    it 'document returns the entire document structure when envelope=true', (done) ->
      @db.writeSnapshot 'c', 'd', {v:1, type:otSimple.uri, data:{str:'Hi'}}, =>

        fetch 'GET', @port, "/doc/c/d?envelope=true", null, (res, data, headers) ->
          assert.strictEqual res.statusCode, 200
          assert.strictEqual headers['x-ot-version'], '1'
          assert.strictEqual headers['x-ot-type'], otSimple.uri
          assert.strictEqual headers['content-type'], 'application/json'
          assert.deepEqual data, {v:1, type:otSimple.uri, data:{str:'Hi'}}
          done()

    it 'a plaintext document is returned as a string', (done) ->
      @db.writeSnapshot 'c', 'd', {v:1, type:otText.uri, data:'hi'}, =>

        fetch 'GET', @port, "/doc/c/d", null, (res, data, headers) ->
          assert.strictEqual res.statusCode, 200
          assert.strictEqual headers['x-ot-version'], '1'
          assert.strictEqual headers['x-ot-type'], otText.uri
          assert.ok headers['etag']
          assert.strictEqual headers['content-type'], 'text/plain'
          assert.deepEqual data, 'hi'
          done()

    it 'ETag is the same between responses', (done) ->
      @db.writeSnapshot 'c', 'd', {v:1, type:otText.uri, data:'hi'}, =>

        fetch 'GET', @port, "/doc/c/d", null, (res, data, headers) =>
          tag = headers['etag']

          # I don't care what the etag is, but if I fetch it again it should be the same.
          fetch 'GET', @port, "/doc/c/d", null, (res, data, headers) ->
            assert.strictEqual headers['etag'], tag
            done()

    it 'ETag changes when version changes', (done) ->
      @db.writeSnapshot 'c', 'd', {v:1, type:otText.uri, data:'hi'}, =>

        fetch 'GET', @port, "/doc/c/d", null, (res, data, headers) =>
          tag = headers['etag']
          @backend.submit 'c', 'd', {v:1, op:['x']}, =>
            fetch 'GET', @port, "/doc/c/d", null, (res, data, headers) =>
              assert.notStrictEqual headers['etag'], tag
              done()


  describe 'GET /ops', ->
    it 'returns ops', (done) ->
      ops = [{v:0, create:{type:otText.uri}}, {v:1, op:[]}, {v:2, op:[]}]
      writeOps @db, 'c', 'd', ops, =>
        fetch 'GET', @port, '/doc/c/d/ops', null, (res, data, headers) ->
          assert.strictEqual res.statusCode, 200
          assert.deepEqual data, ops
          done()

    it 'limits FROM based on query parameter', (done) ->
      ops = [{v:0, create:{type:otText.uri}}, {v:1, op:[]}, {v:2, op:[]}]
      writeOps @db, 'c', 'd', ops, =>
        fetch 'GET', @port, '/doc/c/d/ops?to=2', null, (res, data, headers) ->
          assert.strictEqual res.statusCode, 200
          assert.deepEqual data, [ops[0], ops[1]]
          done()

    it 'limits TO based on query parameter', (done) ->
      ops = [{v:0, create:{type:otText.uri}}, {v:1, op:[]}, {v:2, op:[]}]
      writeOps @db, 'c', 'd', ops, =>
        fetch 'GET', @port, '/doc/c/d/ops?from=1', null, (res, data, headers) ->
          assert.strictEqual res.statusCode, 200
          assert.deepEqual data, [ops[1], ops[2]]
          done()

    it 'returns empty list for nonexistant document', (done) ->
      fetch 'GET', @port, '/doc/c/d/ops', null, (res, data, headers) ->
        assert.strictEqual res.statusCode, 200
        assert.deepEqual data, []
        done()

  describe 'POST', ->
    it 'lets you submit', (done) ->
      called = false
      @backend.submit = (cName, docName, opData, options, callback) ->
        assert.strictEqual cName, 'c'
        assert.strictEqual docName, 'd'
        assert.deepEqual opData, {v:5, op:[1,2,3]}
        called = true
        callback null, 5, []

      fetch 'POST', @port, "/doc/c/d", {v:5, op:[1,2,3]}, (res, ops) =>
        assert.strictEqual res.statusCode, 200
        assert.deepEqual ops, []
        assert called
        done()

    it 'POST a document with invalid JSON returns 400', (done) ->
      fetch 'POST', @port, "/doc/c/d", 'invalid>{json', (res, data) ->
        assert.strictEqual res.statusCode, 400
        done()
    
  describe 'PUT', ->
    it 'PUT a document creates it', (done) ->
      called = false
      @backend.submit = (cName, docName, opData, options, callback) ->
        assert.strictEqual cName, 'c'
        assert.strictEqual docName, 'd'
        assert.deepEqual opData, {create:{type:'simple'}}
        called = true
        callback null, 5, []

      fetch 'PUT', @port, "/doc/c/d", {type:'simple'}, (res, data, headers) =>
        assert.strictEqual res.statusCode, 200
        assert.strictEqual headers['x-ot-version'], '5'

        assert called
        done()

  describe 'DELETE', ->
    it 'deletes a document', (done) ->
      called = false
      @backend.submit = (cName, docName, opData, options, callback) ->
        assert.strictEqual cName, 'c'
        assert.strictEqual docName, 'd'
        assert.deepEqual opData, {del:true}
        called = true
        callback null, 5, []

      fetch 'DELETE', @port, "/doc/c/d", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 200
        assert.strictEqual headers['x-ot-version'], '5'
        assert called
        done()
    

  describe 'with middleware', ->
    describe 'disallowing connections', ->
      beforeEach ->
        @middleware.use 'connect', (action, callback) ->
          assert.equal action.action, 'connect'
          assert action.initialReq.socket.remoteAddress in ['localhost', '127.0.0.1', '::ffff:127.0.0.1'] # Is there a nicer way to do this?

          # This is added in fetch() above
          assert.strictEqual action.initialReq.headers['x-testing'], 'booyah'

          callback 'Forbidden'

      checkResponse = (done) -> (res, data) ->
        #console.log res.statusCode, res.headers, res.body
        assert.strictEqual(res.statusCode, 403)
        assert.deepEqual data, 'Forbidden'
        done()

      it "can't get", (done) ->
        fetch 'GET', @port, "/doc/c/d", null, checkResponse(done)

      it "can't create", (done) ->
        fetch 'PUT', @port, "/doc/c/d", {create:{type:'simple'}, v:0}, checkResponse(done)

      it "can't submit an op", (done) ->
        # Submit an op to a nonexistant doc
        fetch 'POST', @port, "/doc/c/d", {op:{position: 0, text: 'Hi'}, v:0}, checkResponse(done)


  describe 'GET /collection', ->
    # test bellow works only with livedb-mongo adapter

    beforeEach (done) ->
      @db.writeSnapshot @collection, 'iphone6', {v:1, type:otSimple.uri, data:{price: 199, active: true}}, (err)=>
        @db.writeSnapshot @collection, 'iphone6plus', {v:1, type:otSimple.uri, data:{price: 299, active: true}}, (err)=>
          @db.writeSnapshot @collection, 'iphone5s', {v:1, type:otSimple.uri, data:{price: 99, active: false}}, (err)=>
            @db.writeSnapshot @collection, 'iphone5c', {v:1, type:otSimple.uri, data:{price: 0, active: false}}, (err)=>
              done()

    it 'returns list of all documents', (done) ->
      fetch 'GET', @port, "/doc/#{@collection}", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 200
        assert.strictEqual headers['content-type'], 'application/json'
        docNames = data.map (doc)-> doc.docName
        assert.deepEqual docNames, ['iphone6', 'iphone6plus', 'iphone5s', 'iphone5c']
        done()

    it 'returns 400 if invalid JSON in q option', (done) ->
      query = 'invalid>{json'
      fetch 'GET', @port, "/doc/#{@collection}?q=#{query}", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 400
        done()

    it 'returns 400 if invalid JSON in s option', (done) ->
      sort = 'invalid>{json'
      fetch 'GET', @port, "/doc/#{@collection}?s=#{sort}", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 400
        done()

    it 'returns list of documents based on query', (done) ->
      # works only with livedb-mongo adapter

      query = querystring.escape('{"active": true}')
      fetch 'GET', @port, "/doc/#{@collection}?q=#{query}", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 200
        assert.strictEqual headers['content-type'], 'application/json'
        docNames = data.map (doc)-> doc.docName
        assert.deepEqual docNames, ['iphone6', 'iphone6plus']
        done()

    it 'returns sorted list of documents', (done) ->
      # works only with livedb-mongo adapter

      sort = querystring.escape('{"price": 1}')
      fetch 'GET', @port, "/doc/#{@collection}?s=#{sort}", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 200
        assert.strictEqual headers['content-type'], 'application/json'
        docNames = data.map (doc)-> doc.docName
        assert.deepEqual docNames, ['iphone5c', 'iphone5s', 'iphone6', 'iphone6plus']
        done()

    it 'returns limited list of documents, with skip', (done) ->
      # works only with livedb-mongo adapter

      sort = querystring.escape('{"price": 1}')
      fetch 'GET', @port, "/doc/#{@collection}?s=#{sort}&sk=1&l=3", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 200
        assert.strictEqual headers['content-type'], 'application/json'
        docNames = data.map (doc)-> doc.docName
        assert.deepEqual docNames, ['iphone5s', 'iphone6', 'iphone6plus']
        done()

    it 'returns count of documents', (done) ->
      # works only with livedb-mongo adapter

      fetch 'GET', @port, "/doc/#{@collection}?c=true", null, (res, data, headers) =>
        assert.strictEqual res.statusCode, 200
        assert.strictEqual headers['content-type'], 'application/json'
        assert.equal data, '4'
        done()