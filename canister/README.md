# ICP username registry

Backend-only Motoko canister. Clients call it over **ICP’s public HTTP gateway**
(`https://<canister_id>.raw.icp0.io`) — use the **`.raw.`** host so dynamic HTTP
does not require certified assets.

```bash
cd canister
./deploy.sh            # local replica (free)
./deploy.sh mainnet    # needs cycles — you will be asked to confirm
```

Local:

```bash
icp network start -d
icp deploy -y
icp canister status username_registry --id-only
```

Mainnet (top up cycles first):

```bash
icp cycles balance
icp deploy -y -e mainnet
```

`./deploy.sh` prints `registry_url` for clients to configure. Do **not** commit
`.dfx` / `.icp` identities, controllers, or cycle wallets.

Do **not** run bare `icp deploy` when you mean mainnet — that targets local.
