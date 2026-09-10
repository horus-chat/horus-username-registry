// Privacy-first @ registry on ICP (nullifier locks). Never messages / pubkey directory.
// HTTP via ICP boundary nodes: GET/PUT /registry/{user} — no Horus-operated server.
import Text "mo:base/Text";
import HashMap "mo:base/HashMap";
import Result "mo:base/Result";
import Nat16 "mo:base/Nat16";
import Blob "mo:base/Blob";
import Option "mo:base/Option";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";

persistent actor UsernameRegistry {
  type Entry = {
    commitment : Text;
    findable : Bool;
    contact : ?Text;
  };

  type HeaderField = (Text, Text);
  type HttpRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
    certificate_version : ?Nat16;
  };
  type HttpUpdateRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };
  type HttpResponse = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    upgrade : ?Bool;
    streaming_strategy : Null;
  };

  transient var byNullifier = HashMap.HashMap<Text, Entry>(32, Text.equal, Text.hash);
  // username → nullifier (for HTTP path /registry/{user})
  transient var byUser = HashMap.HashMap<Text, Text>(32, Text.equal, Text.hash);
  // owner_hex → current username (one @ per install)
  transient var byOwner = HashMap.HashMap<Text, Text>(32, Text.equal, Text.hash);

  stable var nfEntries : [(Text, Entry)] = [];
  stable var userEntries : [(Text, Text)] = [];
  stable var ownerEntries : [(Text, Text)] = [];

  system func preupgrade() {
    nfEntries := Iter.toArray(byNullifier.entries());
    userEntries := Iter.toArray(byUser.entries());
    ownerEntries := Iter.toArray(byOwner.entries());
  };

  system func postupgrade() {
    byNullifier := HashMap.fromIter<Text, Entry>(nfEntries.vals(), Nat.max(nfEntries.size(), 1), Text.equal, Text.hash);
    byUser := HashMap.fromIter<Text, Text>(userEntries.vals(), Nat.max(userEntries.size(), 1), Text.equal, Text.hash);
    byOwner := HashMap.fromIter<Text, Text>(ownerEntries.vals(), Nat.max(ownerEntries.size(), 1), Text.equal, Text.hash);
    nfEntries := [];
    userEntries := [];
    ownerEntries := [];
  };

  func validHex64(s : Text) : Bool {
    if (s.size() != 64) { return false };
    for (c in s.chars()) {
      let ok =
        (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
      if (not ok) { return false };
    };
    true
  };

  func validContact(findable : Bool, contact : ?Text) : Bool {
    switch (findable, contact) {
      case (true, ?c) {
        let n = c.size();
        n >= 8 and n <= 8192
      };
      case (true, null) { false };
      case (false, _) { true };
    }
  };

  func normalizeUser(u : Text) : Text {
    Text.toLowercase(Text.trim(u, #char ' '))
  };

  func releaseUser(user : Text) {
    switch (byUser.remove(user)) {
      case (?nf) { ignore byNullifier.remove(nf) };
      case null {};
    };
  };

  func putClaim(user : Text, key : Text, owner : Text, entry : Entry) {
    byNullifier.put(key, entry);
    if (user != "") { byUser.put(user, key) };
    byOwner.put(owner, user);
  };

  func claimInner(
    username : Text,
    nullifier : Text,
    commitment : Text,
    findable : Bool,
    contact : ?Text,
    ownerHex : Text
  ) : Result.Result<(), Text> {
    let user = normalizeUser(username);
    let key = Text.toLowercase(nullifier);
    let owner = Text.toLowercase(ownerHex);
    if (not validHex64(key)) { return #err("bad nullifier") };
    if (not validHex64(Text.toLowercase(commitment))) { return #err("bad commitment") };
    if (not validHex64(owner)) { return #err("bad owner") };
    if (not validContact(findable, contact)) { return #err("bad contact") };
    if (user == "" or user.size() < 3 or user.size() > 32) { return #err("bad username") };
    let storedContact = if (findable) { contact } else { null };
    let entry : Entry = {
      commitment = Text.toLowercase(commitment);
      findable = findable;
      contact = storedContact;
    };
    switch (byOwner.get(owner)) {
      case (?current) {
        if (current == user) {
          putClaim(user, key, owner, entry);
          return #ok(());
        };
        switch (byUser.get(user)) {
          case (?_) { #err("taken") };
          case null {
            releaseUser(current);
            putClaim(user, key, owner, entry);
            #ok(());
          };
        };
      };
      case null {
        switch (byUser.get(user)) {
          case (?_) { #err("taken") };
          case null {
            putClaim(user, key, owner, entry);
            #ok(());
          };
        };
      };
    };
  };

  public shared func claim(
    nullifier : Text,
    commitment : Text,
    findable : Bool,
    contact : ?Text
  ) : async Result.Result<(), Text> {
    #err("owner required")
  };

  public query func isTaken(nullifier : Text) : async Bool {
    Option.isSome(byNullifier.get(Text.toLowercase(nullifier)))
  };

  public query func resolve(nullifier : Text) : async ?Text {
    switch (byNullifier.get(Text.toLowercase(nullifier))) {
      case (?e) { if (e.findable) { e.contact } else { null } };
      case null { null };
    }
  };

  /// Sole controller (your `horus` identity). HTTP clients cannot call this.
  let admin : Principal = Principal.fromText("otjol-cob6q-g7pdk-ctufj-p2r3m-v4yrt-ukimd-heima-63ps6-mymgm-vae");

  /// All claimed @ handles. Empty unless called by the controller.
  public query ({ caller }) func listUsernames() : async [Text] {
    if (caller != admin) { return [] };
    Iter.toArray(byUser.keys())
  };

  public query ({ caller }) func userCount() : async Nat {
    if (caller != admin) { return 0 };
    byUser.size()
  };

  func http(code : Nat16, body : Text) : HttpResponse {
    {
      status_code = code;
      headers = [
        ("content-type", "text/plain; charset=utf-8"),
        ("access-control-allow-origin", "*"),
      ];
      body = Text.encodeUtf8(body);
      upgrade = null;
      streaming_strategy = null;
    }
  };

  func stripQuery(url : Text) : Text {
    var out = "";
    label scan for (c in url.chars()) {
      if (c == '?') { break scan };
      out #= Text.fromChar(c);
    };
    out
  };

  func parsePath(url : Text) : ?(Text, Bool) {
    let path = stripQuery(url);
    if (not Text.startsWith(path, #text "/registry/")) { return null };
    let rest = Text.trimStart(path, #text "/registry/");
    if (Text.endsWith(rest, #text "/taken")) {
      let name = Text.trimEnd(rest, #text "/taken");
      if (name == "") { null } else { ?(name, true) }
    } else if (Text.contains(rest, #char '/')) {
      null
    } else if (rest == "") {
      null
    } else {
      ?(rest, false)
    }
  };

  /// Extract "key":"value" (very small JSON helper).
  func jsonString(body : Text, key : Text) : ?Text {
    let pattern = "\"" # key # "\":\"";
    if (not Text.contains(body, #text pattern)) {
      let pattern2 = "\"" # key # "\": \"";
      if (not Text.contains(body, #text pattern2)) { return null };
      return extractAfter(body, pattern2);
    };
    extractAfter(body, pattern)
  };

  func extractAfter(body : Text, pattern : Text) : ?Text {
    // split once on pattern, take until next quote (JSON-unescape `\/` etc.)
    let iter = Text.split(body, #text pattern);
    ignore iter.next(); // before
    switch (iter.next()) {
      case null { null };
      case (?rest) {
        var out = "";
        var escaped = false;
        label chars for (c in rest.chars()) {
          if (escaped) {
            out #= Text.fromChar(c);
            escaped := false;
          } else if (c == '\\') {
            escaped := true;
          } else if (c == '\"') {
            break chars;
          } else {
            out #= Text.fromChar(c);
          };
        };
        ?out
      };
    }
  };

  func jsonBool(body : Text, key : Text) : Bool {
    Text.contains(body, #text ("\"" # key # "\":true"))
      or Text.contains(body, #text ("\"" # key # "\": true"))
  };

  public query func http_request(req : HttpRequest) : async HttpResponse {
    let method = Text.toUppercase(req.method);
    if (method == "OPTIONS") {
      return {
        status_code = 204;
        headers = [
          ("access-control-allow-origin", "*"),
          ("access-control-allow-methods", "GET, PUT, OPTIONS"),
          ("access-control-allow-headers", "content-type"),
        ];
        body = Blob.fromArray([]);
        upgrade = null;
        streaming_strategy = null;
      };
    };
    if (method == "PUT" or method == "POST") {
      return {
        status_code = 200;
        headers = [];
        body = Blob.fromArray([]);
        upgrade = ?true;
        streaming_strategy = null;
      };
    };
    if (method != "GET") { return http(405, "method not allowed") };
    let path = stripQuery(req.url);
    if (path == "/health" or path == "/") { return http(200, "ok") };
    switch (parsePath(req.url)) {
      case null { http(404, "not found") };
      case (?(user, takenOnly)) {
        let u = normalizeUser(user);
        switch (byUser.get(u)) {
          case null {
            if (takenOnly) { http(200, "0") } else { http(404, "not found") }
          };
          case (?nf) {
            if (takenOnly) { http(200, "1") }
            else {
              switch (byNullifier.get(nf)) {
                case (?e) {
                  if (e.findable) {
                    switch (e.contact) {
                      case (?c) { http(200, c) };
                      case null { http(404, "not found") };
                    }
                  } else { http(404, "not found") }
                };
                case null { http(404, "not found") };
              }
            }
          };
        }
      };
    }
  };

  public shared func http_request_update(req : HttpUpdateRequest) : async HttpResponse {
    let method = Text.toUppercase(req.method);
    if (method != "PUT" and method != "POST") {
      return http(405, "method not allowed");
    };
    switch (parsePath(req.url)) {
      case null { http(404, "not found") };
      case (?(user, takenOnly)) {
        if (takenOnly) { return http(400, "bad path") };
        let bodyText = switch (Text.decodeUtf8(req.body)) {
          case (?t) { t };
          case null { return http(400, "bad body") };
        };
        let nullifier = switch (jsonString(bodyText, "nullifier_hex")) {
          case (?n) { n };
          case null { return http(400, "nullifier_hex required") };
        };
        let commitment = switch (jsonString(bodyText, "commitment_hex")) {
          case (?c) { c };
          case null { return http(400, "commitment_hex required") };
        };
        let findable = jsonBool(bodyText, "findable");
        let contact = jsonString(bodyText, "contact");
        let owner = switch (jsonString(bodyText, "owner_hex")) {
          case (?o) { o };
          case null { return http(400, "owner_hex required") };
        };
        switch (claimInner(user, nullifier, commitment, findable, contact, owner)) {
          case (#ok(())) { http(201, "claimed") };
          case (#err("taken")) { http(409, "taken") };
          case (#err(e)) { http(400, e) };
        }
      };
    }
  };
};
