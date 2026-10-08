import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import * as Schema from 'effect/Schema';
import { ProviderInstanceConfig } from './packages/contracts/src/providerInstance.ts';
import { ServerSettings } from './packages/contracts/src/settings.ts';
import { WsRpcGroup } from './packages/contracts/src/rpc.ts';

const fixtures = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const legacy = process.argv[3] === "legacy";
let checks = 0;
let requestChecks = 0;
for (const { id, instance } of fixtures.instances) {
  const decoded = Schema.decodeUnknownSync(ProviderInstanceConfig)(instance);
  assert.equal(decoded.driver, instance.driver);
  assert.equal(decoded.accentColor, instance.accentColor);
  const settings = Schema.decodeUnknownSync(ServerSettings)({providerInstances: {[id]: instance}});
  assert.equal(settings.providerInstances[id].displayName, instance.displayName);
  checks += 2;
}
for (const request of fixtures.requests) {
  if (request.legacy !== undefined && request.legacy !== legacy) continue;
  const rpc = WsRpcGroup.requests.get(request.tag);
  assert.ok(rpc, `T3 no longer exposes ${request.tag}`);
  const decoded = Schema.decodeUnknownSync(rpc.payloadSchema)(request.payload);
  if (request.tag === 'server.updateSettings') {
    if (legacy) {
      assert.deepEqual(JSON.parse(JSON.stringify(decoded.patch.providerInstances)), request.payload.patch.providerInstances);
    } else {
    assert.equal(decoded.providerInstanceMutation.instanceId, request.payload.providerInstanceMutation.instanceId);
    assert.equal(decoded.providerInstanceMutation.operation, 'upsert');
    }
  }
  checks++;
  requestChecks++;
}
// Make sure the check actually rejects a malformed Harnais profile/request.
assert.throws(() => Schema.decodeUnknownSync(ProviderInstanceConfig)({driver: 'bad/path'}));
assert.throws(() => Schema.decodeUnknownSync(WsRpcGroup.requests.get('provider.auth.start').payloadSchema)({}));
checks += 2;
const result = {checks, profiles: fixtures.instances.length, requests: requestChecks};
writeFileSync('result.json', JSON.stringify(result, null, 2));
console.log(JSON.stringify(result));
