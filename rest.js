// This implements ShareJS's REST API.

var Router = require('express').Router;
var url = require('url');


// ****  Utility functions


var send403 = function(res, message) {
  if (message == null) message = 'Forbidden\n';

  res.writeHead(403, {'Content-Type': 'text/plain'});
  res.end(message);
};

var send404 = function(res, message) {
  if (message == null) message = '404: Your document could not be found.\n';

  res.writeHead(404, {'Content-Type': 'text/plain'});
  res.end(message);
};

var send409 = function(res, message) {
  if (message == null) message = '409: Your operation could not be applied.\n';

  res.writeHead(409, {'Content-Type': 'text/plain'});
  res.end(message);
};

var sendError = function(res, message, head) {
  if (message === 'forbidden') {
    if (head) {
      send403(res, "");
    } else {
      send403(res);
    }
  } else if (message === 'Document created remotely') {
    if (head) {
      send409(res, "");
    } else {
      send409(res, message + '\n');
    }
  } else {
    //console.warn("REST server does not know how to send error:", message);
    if (head) {
      res.writeHead(500, {});
      res.end("");
    } else {
      res.writeHead(500, {'Content-Type': 'text/plain'});
      res.end("Error: " + message + "\n");
    }
  }
};

var send400 = function(res, message) {
  res.writeHead(400, {'Content-Type': 'text/plain'});
  res.end(message);
};

var send200 = function(res, message) {
  if (message == null) message = "OK\n";

  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end(message);
};

var sendJSON = function(res, obj) {
  res.writeHead(200, {'Content-Type': 'application/json'});
  res.end(JSON.stringify(obj) + '\n');
};

// Expect the request to contain JSON data. Read all the data and try to JSON
// parse it.
var expectJSONObject = function(req, res, callback) {
  pump(req, function(data) {
    var obj;
    try {
      obj = JSON.parse(data);
    } catch (err) {
      send400(res, 'Supplied JSON invalid');
      return;
    }

    return callback(obj);
  });
};

var pump = function(req, callback) {
  // Currently using the old streams API..
  var data = '';
  req.on('data', function(chunk) {
    return data += chunk;
  });
  return req.on('end', function() {
    return callback(data);
  });
};



// ***** Actual logic

module.exports = function(backend) {
  var router = new Router();

  router.use(function(req, res, next) {
    if (req.session && req.session.shareAgent) {
      req._shareAgent = req.session.shareAgent;
      next();
    } else {
      var agent;

      if (backend.as) {
        req._shareAgent = agent = backend.as(req);
        if (req.session) req.session.shareAgent = agent;

        agent.connect(null, req, function(err) {
          if (err && typeof err === 'string')
            err = Error(err);

          next(err);
        });
      } else {
        req._shareAgent = agent = backend;
        if (req.session) req.session.shareAgent = agent;

        agent = backend;
        next();
      }
    }
  });

  // Get list of documents.
  // interface similar to mongolab - http://docs.mongolab.com/restapi/#list-documents
  // - q=<query> - restrict results by the specified JSON query
  // - c=true - return the result count for this query
  // - s=<sort order> - specify the order in which to sort each specified field (1- ascending; -1 - descending)
  // - sk=<num results to skip> - specify the number of results to skip in the result set; useful for paging
  // - l=<limit> - specify the limit for the number of results
  router.get('/:cName', function(req, res, next) {
    var query = url.parse(req.url, true).query;

    // build fetch query object
    var fetchQuery = {};
    if (query.q) {
      try {
        fetchQuery = JSON.parse(query.q);
      } catch (e) {
        return send400(res, 'Cannot parse "q" option: invalid JSON');
      }
    }

    // sort
    if (query.s) {
      try {
        fetchQuery.$orderby = JSON.parse(query.s);
      } catch (e) {
        return send400(res, 'Cannot parse "s" option: invalid JSON');
      }
    }

    // limit & skip
    if (query.sk) fetchQuery.$skip = parseInt(query.sk, 10);
    if (query.l) fetchQuery.$limit = parseInt(query.l, 10);

    // count
    if (query.c == 'true') fetchQuery.$count = true;

    var fetchOptions = {docMode: 'fetch'};
    var cName = req.params.cName;
    req._shareAgent.queryFetch(cName, fetchQuery, fetchOptions, function(err, results, extra) {
      if (err) {
        if (req.method === "HEAD") {
          sendError(res, err, true);
        } else {
          sendError(res, err);
        }
        return;
      }

      // If not GET request, presume HEAD request
      if (req.method !== 'GET') {
        send200(res, '');
        return;
      }

      var contents = {
        meta: {
          limit: fetchQuery.$limit || null,
          offset: fetchQuery.$skip || 0,
          total_count: extra || results.length
        }
      };

      // return only meta
      if (query.c) {
        sendJSON(res, contents);
        return;
      } else {
        contents.objects = results;
      }

      if (fetchQuery.$limit || fetchQuery.$skip) {
        fetchQuery.$count = true;
        req._shareAgent.queryFetch(cName, fetchQuery, fetchOptions, function(err, results, extra) {
          contents.meta.total_count = extra;
          sendJSON(res, contents);
        });
        return;
      }

      sendJSON(res, contents);
    })
  });
  
  // GET returns the document snapshot. The version and type are sent as headers.
  // I'm not sure what to do with document metadata - it is inaccessable for now.
  router.get('/:cName/:docName', function(req, res, next) {
    req._shareAgent.fetch(req.params.cName, req.params.docName, function(err, doc) {
      if (err) {
        if (req.method === "HEAD") {
          sendError(res, err, true);
        } else {
          sendError(res, err);
        }
        return;
      }

      res.setHeader('X-OT-Version', doc.v);

      if (!doc.type) {
        send404(res, 'Document does not exist\n');
        return;
      }

      res.setHeader('X-OT-Type', doc.type);
      res.setHeader('ETag', doc.v);

      // If not GET request, presume HEAD request
      if (req.method !== 'GET') {
        send200(res, '');
        return;
      }

      var content;
      var query = url.parse(req.url,true).query;
      if (query.envelope == 'true')
      {
        content = doc;
      } else {
        content = doc.data;
      }

      if (typeof doc.data === 'string') {
        send200(res, content);
      } else {
        sendJSON(res, content);
      }
    });
  });

  // Get operations. You can use from:X and to:X to specify the range of ops you want.
  router.get('/:cName/:docName/ops', function(req, res, next) {
    var from = 0, to = null;

    var query = url.parse(req.url, true).query;

    if (query && query.from) from = parseInt(query.from)|0;
    if (query && query.to) to = parseInt(query.to)|0;

    req._shareAgent.getOps(req.params.cName, req.params.docName, from, to, function(err, ops) {
      if (err)
        sendError(res, err);
      else
        sendJSON(res, ops);
    });
  });

  var submit = function(req, res, opData, sendOps) {
    // The backend allows the version to be unspecified - it assumes the most
    // recent version in that case. This is useful behaviour when you want to
    // create a document.
    req._shareAgent.submit(req.params.cName, req.params.docName, opData, {}, function(err, v, ops) {
      if (err) return sendError(res, err);

      res.setHeader('X-OT-Version', v);
      if (sendOps)
        sendJSON(res, ops);
      else
        send200(res);
    });
  };

  // POST submits op data to the document. POST {op:[...], v:100}
  router.post('/:cName/:docName', function(req, res, next) {
    expectJSONObject(req, res, function(opData) {
      submit(req, res, opData, true);
    });
  });
  

  // PUT is used to create a document. The contents are a JSON object with
  // {type:TYPENAME, data:{initial data} meta:{...}}
  // PUT {...} is equivalent to POST {create:{...}}
  router.put('/:cName/:docName', function(req, res, next) {
    expectJSONObject(req, res, function(create) {
      submit(req, res, {create:create});
    });
  });

  // DELETE deletes a document. It is equivalent to POST {del:true}
  router.delete('/:cName/:docName', function(req, res, next) {
    submit(req, res, {del:true});
  });

  router.use(function(req, res) {
    // Prevent memory leaks.
    console.log('removing');
    delete req._shareAgent.req;
  });

  return router;
};

