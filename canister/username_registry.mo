// ICP Motoko canister — username nullifiers + commitments only. Never messages.
// Client hashes username → nullifier; chain never stores a plaintext pubkey directory.
//
// HTTP interface (ICP raw gateway *.raw.icp0.io):
//   GET  /registry/{nullifier_hex}         → resolve: contact blob or 404
//   GET  /registry/{nullifier_hex}/taken   → isTaken: "1" or "0"
//   GET  /health                           → "ok"
//   PUT  /registry/{nullifier_hex}         → claim (upgrade to http_request_update)
//
// Writes go through http_request_update (ICP update call via raw gateway).
// Reads go through http_request (query call — fast + no fees).
import Text "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Result "mo:base/Result";
import Nat "mo:base/Nat";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Char "mo:base/Char";

actor UsernameRegistry {
  // ─── Storage ───────────────────────────────────────────────────────────────

  type Entry = {
    commitment : Text;
    findable : Bool;
    contact : ?Text;
    owner : ?Text;
  };

  stable var entries : [(Text, Entry)] = [];
  var map = HashMap.fromIter<Text, Entry>(entries.vals(), 10, Text.equal, Text.hash);

  system func preupgrade() {
    entries := Iter.toArray(map.entries());
  };

  system func postupgrade() {
    map := HashMap.fromIter<Text, Entry>(entries.vals(), Nat.max(entries.size(), 1), Text.equal, Text.hash);
    entries := [];
  };

  // ─── Validation ────────────────────────────────────────────────────────────

  func isHexChar(c : Char) : Bool {
    (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')
  };

  func validHex64(s : Text) : Bool {
    if (s.size() != 64) { return false };
    for (c in s.chars()) { if (not isHexChar(c)) { return false } };
    true
  };

  func validContact(findable : Bool, contact : ?Text) : Bool {
    switch (findable, contact) {
      case (true, ?c) { let n = c.size(); n >= 8 and n <= 8192 };
      case (true, null) { false };
      case (false, _) { true };
    }
  };

  // ─── Minimal JSON field extraction ─────────────────────────────────────────
  // Handles the compact + whitespace-tolerant JSON the mobile apps send.

  /// Find the first occurrence of `needle` in `haystack`; returns the byte
  /// offset past the needle, or null.
  func findAfter(haystack : Text, needle : Text) : ?Text {
    let hArr = Iter.toArray(haystack.chars());
    let nArr = Iter.toArray(needle.chars());
    let hLen = hArr.size();
    let nLen = nArr.size();
    if (nLen == 0 or nLen > hLen) { return null };
    var i = 0;
    while (i + nLen <= hLen) {
      var match = true;
      var j = 0;
      label check while (j < nLen) {
        if (hArr[i + j] != nArr[j]) { match := false; break check };
        j += 1;
      };
      if (match) {
        // Return the suffix after the needle.
        var rest = "";
        var k = i + nLen;
        while (k < hLen) { rest := rest # Text.fromChar(hArr[k]); k += 1 };
        return ?rest;
      };
      i += 1;
    };
    null
  };

  /// Extract the string value of a JSON field (no nested objects, no escaped
  /// quotes in values — sufficient for our invite blobs and hex strings).
  func jsonString(json : Text, key : Text) : ?Text {
    let needle = "\"" # key # "\":\"";
    switch (findAfter(json, needle)) {
      case null { null };
      case (?rest) {
        // Read until the next unescaped '"'.
        var value = "";
        var prev = '\\'; // dummy init
        var first = true;
        for (c in rest.chars()) {
          if (first) { first := false };
          if (c == '"' and not first and prev != '\\') {
            return ?value
          };
          value := value # Text.fromChar(c);
          prev := c;
        };
        null
      };
    }
  };

  /// Extract a boolean JSON field value.
  func jsonBool(json : Text, key : Text) : Bool {
    Text.contains(json, #text ("\"" # key # "\":true"))
  };

  // ─── Candid methods ────────────────────────────────────────────────────────

  public shared func claim(
    nullifier : Text,
    commitment : Text,
    findable : Bool,
    contact : ?Text,
    owner : ?Text
  ) : async Result.Result<(), Text> {
    let key = Text.toLower(nullifier);
    if (not validHex64(key)) { return #err("bad nullifier") };
    if (not validHex64(Text.toLower(commitment))) { return #err("bad commitment") };
    if (not validContact(findable, contact)) { return #err("bad contact") };
    switch (map.get(key)) {
      case (?existing) {
        switch (existing.owner, owner) {
          case (?stored, ?incoming) {
            if (stored != incoming) { return #err("taken") };
          };
          case (null, ?_) { };
          case (_, null) { return #err("owner required") };
        };
        map.put(key, {
          commitment = Text.toLower(commitment);
          findable;
          contact = if (findable) { contact } else { null };
          owner;
        });
        #ok(())
      };
      case null {
        map.put(key, {
          commitment = Text.toLower(commitment);
          findable;
          contact = if (findable) { contact } else { null };
          owner;
        });
        #ok(())
      };
    }
  };

  public query func isTaken(nullifier : Text) : async Bool {
    switch (map.get(Text.toLower(nullifier))) {
      case (?_) true;
      case null false;
    }
  };

  public query func resolve(nullifier : Text) : async ?Text {
    switch (map.get(Text.toLower(nullifier))) {
      case (?e) { if (e.findable) { e.contact } else { null } };
      case null null;
    }
  };

  // ─── HTTP types ────────────────────────────────────────────────────────────

  public type HeaderField = (Text, Text);
  public type HttpRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };
  public type HttpResponse = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    // upgrade: if true, ICP will re-issue as http_request_update (an update call).
    upgrade : ?Bool;
  };

  // ─── HTTP helpers ──────────────────────────────────────────────────────────

  func stripQuery(url : Text) : Text {
    switch (findAfter(url, "?")) {
      // findAfter returns the SUFFIX after "?", so we want the prefix.
      case (?_) {
        var path = "";
        for (c in url.chars()) {
          if (c == '?') { return path };
          path := path # Text.fromChar(c);
        };
        path
      };
      case null { url };
    }
  };

  let corsHeaders : [HeaderField] = [
    ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "GET, PUT, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type"),
  ];

  func resp(code : Nat16, body : Text) : HttpResponse {
    {
      status_code = code;
      headers = Array.append<HeaderField>(corsHeaders, [("Content-Type", "text/plain; charset=utf-8")]);
      body = Text.encodeUtf8(body);
      upgrade = null;
    }
  };

  /// Extract the path segment after "/registry/" (without leading slash).
  func registrySegment(path : Text) : ?Text {
    let prefix = "/registry/";
    switch (findAfter(path, prefix)) {
      case null null;
      case (?rest) ?rest;
    }
  };

  // ─── http_request — query (GET, OPTIONS) ───────────────────────────────────

  public query func http_request(request : HttpRequest) : async HttpResponse {
    let path = stripQuery(request.url);

    if (request.method == "OPTIONS") {
      return { status_code = 204; headers = corsHeaders; body = Text.encodeUtf8(""); upgrade = null };
    };

    if (path == "/health" or path == "/") {
      return resp(200, "ok");
    };

    // PUT requests cannot be served by a query — signal ICP to upgrade.
    if (request.method == "PUT" or request.method == "POST") {
      return { status_code = 200; headers = []; body = Text.encodeUtf8(""); upgrade = ?true };
    };

    // GET /registry/{nullifier}[/taken]
    switch (registrySegment(path)) {
      case null { resp(404, "not found") };
      case (?segment) {
        if (Text.endsWith(segment, #text "/taken")) {
          // /registry/{nullifier}/taken
          let nullifier = Text.trimEnd(segment, #text "/taken");
          if (not validHex64(nullifier)) { return resp(400, "bad nullifier") };
          let key = Text.toLower(nullifier);
          let taken = switch (map.get(key)) { case (?_) "1"; case null "0" };
          resp(200, taken)
        } else if (validHex64(segment)) {
          // /registry/{nullifier}
          let key = Text.toLower(segment);
          switch (map.get(key)) {
            case null { resp(404, "not found") };
            case (?e) {
              if (not e.findable) { return resp(404, "not findable") };
              switch (e.contact) {
                case (?c) { resp(200, c) };
                case null { resp(404, "not findable") };
              }
            };
          }
        } else {
          resp(400, "bad nullifier")
        }
      };
    }
  };

  // ─── http_request_update — update call (PUT/claim) ─────────────────────────
  //
  // ICP upgrades the call here when http_request returns upgrade = ?true.
  // The body is the JSON claim payload from the mobile app.

  public func http_request_update(request : HttpRequest) : async HttpResponse {
    let path = stripQuery(request.url);

    switch (registrySegment(path)) {
      case null { resp(404, "not found") };
      case (?segment) {
        // Only support PUT /registry/{nullifier}
        if (request.method != "PUT") { return resp(405, "method not allowed") };
        if (not validHex64(segment)) { return resp(400, "bad nullifier") };
        let nullifier = Text.toLower(segment);

        // Parse body JSON.
        let bodyText = switch (Text.decodeUtf8(request.body)) {
          case null { return resp(400, "bad body") };
          case (?t) t;
        };

        let commitHex = switch (jsonString(bodyText, "commitment_hex")) {
          case null { return resp(400, "missing commitment_hex") };
          case (?c) { if (not validHex64(c)) { return resp(400, "bad commitment_hex") }; Text.toLower(c) };
        };

        let findable = jsonBool(bodyText, "findable");

        let contact : ?Text = if (findable) {
          switch (jsonString(bodyText, "contact")) {
            case null { return resp(400, "missing contact for findable claim") };
            case (?c) {
              let n = c.size();
              if (n < 8 or n > 8192) { return resp(400, "contact too short or too long") };
              ?c
            };
          }
        } else { null };

        let ownerHex = switch (jsonString(bodyText, "owner_hex")) {
          case null { return resp(400, "missing owner_hex") };
          case (?o) {
            if (not validHex64(o)) { return resp(400, "bad owner_hex") };
            ?Text.toLower(o)
          };
        };

        // New claim or owner-verified invite refresh (same nullifier, new contact blob).
        switch (map.get(nullifier)) {
          case (?existing) {
            switch (existing.owner, ownerHex) {
              case (?stored, ?incoming) {
                if (stored != incoming) { return resp(409, "taken") };
              };
              case (null, ?incoming) {
                // Legacy row: bind owner on first refresh from the device that holds the secret.
              };
              case (_, null) { return resp(400, "missing owner_hex") };
            };
            map.put(nullifier, {
              commitment = commitHex;
              findable;
              contact;
              owner = ownerHex;
            });
            resp(200, "updated")
          };
          case null {
            map.put(nullifier, {
              commitment = commitHex;
              findable;
              contact;
              owner = ownerHex;
            });
            resp(201, "claimed")
          };
        }
      };
    }
  };
};
