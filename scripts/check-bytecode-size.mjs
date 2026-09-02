import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const limit = 24_576;
const contracts = [
  "KeiboCampaignEscrow",
  "KeiboInvestmentReceipt",
  "KeiboGovernance",
  "KeiboDealRoomEvidence",
];

for (const name of contracts) {
  const artifactPath = resolve(
    "artifacts",
    "contracts",
    `${name}.sol`,
    `${name}.json`,
  );
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const bytecode = String(artifact.deployedBytecode ?? "0x").replace(/^0x/, "");
  const bytes = bytecode.length / 2;
  if (bytes <= 0 || bytes >= limit) {
    throw new Error(`${name} deployed bytecode is ${bytes} bytes; limit is ${limit}`);
  }
  process.stdout.write(`${name}: ${bytes} bytes\n`);
}
