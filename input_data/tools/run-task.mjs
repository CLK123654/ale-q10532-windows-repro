import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseAllDocuments } from "yaml";

const inputRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const packageRoot = path.resolve(inputRoot, "..");
const outputRoot = path.join(packageRoot, "output");
const chartRoot = path.join(outputRoot, "chart", "feature-freeze-control");
const reportRoot = path.join(outputRoot, "reports");
const stageRoot = path.join(packageRoot, ".feature_freeze_stage");
const policyPath = path.join(inputRoot, "policy", "asset_contract.json");
const policyArg = policyPath.replaceAll("\\", "/");
const casesPath = path.join(inputRoot, "cases", "render_cases.csv");
const helmBin = process.env.HELM_BIN || "helm";

function ensure(condition, message) {
  if (!condition) throw new Error(message);
}

function runHelm(args) {
  const result = spawnSync(helmBin, args, { cwd: packageRoot, encoding: "utf8", timeout: 60000 });
  if (result.error) throw result.error;
  ensure(result.status === 0, result.stderr || result.stdout || `Helm命令结束状态为${result.status}`);
  return result.stdout;
}

function csvCell(value) {
  const text = value === null || value === undefined ? "" : String(value);
  return /[",\n\r]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

async function writeCsv(target, columns, rows) {
  const lines = [columns.join(","), ...rows.map((row) => columns.map((column) => csvCell(row[column])).join(","))];
  await fs.writeFile(target, `${lines.join("\n")}\n`, "utf8");
}

function parseCsv(text) {
  const lines = text.trim().split(/\r?\n/);
  const headers = lines.shift().split(",");
  return lines.map((line) => Object.fromEntries(line.split(",").map((value, index) => [headers[index], value])));
}

function readDocuments(text) {
  return parseAllDocuments(text).map((document) => {
    ensure(document.errors.length === 0, document.errors[0]?.message || "Helm渲染文档无法读取");
    return document.toJSON();
  }).filter(Boolean);
}

async function main() {
  await fs.rm(stageRoot, { recursive: true, force: true });
  await fs.rm(reportRoot, { recursive: true, force: true });
  try {
    const [policyText, casesText] = await Promise.all([
      fs.readFile(policyPath, "utf8"),
      fs.readFile(casesPath, "utf8")
    ]);
    const policy = JSON.parse(policyText);
    const cases = parseCsv(casesText);
    ensure(cases.length > 0, "发布案例清单为空");
    ensure((await fs.stat(chartRoot)).isDirectory(), "完成Chart不存在");

    const helmVersion = runHelm(["version", "--short"]).trim();
    const inventoryRows = [];
    const permissionRows = [];
    const boundaryRows = [];
    const hookRows = [];
    const caseRows = [];

    for (const item of cases) {
      const valuesPath = path.join(inputRoot, "cases", item.values_file);
      const shared = [chartRoot, "--namespace", item.namespace, "-f", valuesPath, "--set-file", `contract.document=${policyArg}`];
      runHelm(["lint", ...shared]);
      const documents = readDocuments(runHelm(["template", item.release_name, ...shared]));

      for (const object of documents) {
        const annotations = object.metadata?.annotations || {};
        inventoryRows.push({
          case_id: item.case_id,
          api_version: object.apiVersion,
          kind: object.kind,
          name: object.metadata?.name,
          namespace: object.metadata?.namespace,
          hook_phase: annotations["helm.sh/hook"] || "",
          hook_weight: annotations["helm.sh/hook-weight"] || ""
        });

        if (object.kind === "Role") {
          for (const rule of object.rules || []) {
            for (const resource of rule.resources || []) {
              for (const verb of rule.verbs || []) {
                permissionRows.push({ case_id: item.case_id, api_group: (rule.apiGroups || [""])[0], resource, verb });
              }
            }
          }
        }

        if (object.kind === "NetworkPolicy") {
          for (const ingress of object.spec?.ingress || []) {
            for (const peer of ingress.from || []) {
              for (const port of ingress.ports || []) {
                boundaryRows.push({
                  case_id: item.case_id,
                  direction: "ingress",
                  peer_type: "pod_label",
                  peer_value: peer.podSelector?.matchLabels?.["app.kubernetes.io/name"] || "",
                  protocol: port.protocol,
                  port: port.port
                });
              }
            }
          }
          for (const egress of object.spec?.egress || []) {
            for (const peer of egress.to || []) {
              for (const port of egress.ports || []) {
                const isCidr = Boolean(peer.ipBlock?.cidr);
                boundaryRows.push({
                  case_id: item.case_id,
                  direction: "egress",
                  peer_type: isCidr ? "cidr" : "namespace_pod",
                  peer_value: isCidr ? peer.ipBlock.cidr : `${peer.namespaceSelector?.matchLabels?.["kubernetes.io/metadata.name"] || ""}/${peer.podSelector?.matchLabels?.["k8s-app"] || ""}`,
                  protocol: port.protocol,
                  port: port.port
                });
              }
            }
          }
        }

        if (object.kind === "Job") {
          hookRows.push({
            case_id: item.case_id,
            job_name: object.metadata.name,
            hook_phase: annotations["helm.sh/hook"],
            hook_weight: annotations["helm.sh/hook-weight"],
            deadline_seconds: object.spec.activeDeadlineSeconds,
            delete_policy: String(annotations["helm.sh/hook-delete-policy"] || "").replaceAll(",", ";")
          });
        }
      }

      const deployment = documents.find((object) => object.kind === "Deployment");
      const policyMode = deployment?.spec?.template?.spec?.containers?.[0]?.env?.find((entry) => entry.name === "POLICY_MODE")?.value;
      caseRows.push({
        case_id: item.case_id,
        release_name: item.release_name,
        namespace: item.namespace,
        replica_count: deployment?.spec?.replicas,
        policy_mode: policyMode,
        object_count: documents.length
      });
    }

    await fs.mkdir(stageRoot, { recursive: true });
    await writeCsv(path.join(stageRoot, "rendered_object_inventory.csv"), ["case_id", "api_version", "kind", "name", "namespace", "hook_phase", "hook_weight"], inventoryRows);
    await writeCsv(path.join(stageRoot, "rbac_permissions.csv"), ["case_id", "api_group", "resource", "verb"], permissionRows);
    await writeCsv(path.join(stageRoot, "network_boundaries.csv"), ["case_id", "direction", "peer_type", "peer_value", "protocol", "port"], boundaryRows);
    await writeCsv(path.join(stageRoot, "hook_sequence.csv"), ["case_id", "job_name", "hook_phase", "hook_weight", "deadline_seconds", "delete_policy"], hookRows);
    await fs.writeFile(path.join(stageRoot, "release_handover.json"), `${JSON.stringify({
      contract_id: policy.contract_id,
      helm_version: helmVersion,
      release_cases: caseRows,
      report_rows: {
        rendered_object_inventory: inventoryRows.length,
        rbac_permissions: permissionRows.length,
        network_boundaries: boundaryRows.length,
        hook_sequence: hookRows.length
      }
    }, null, 2)}\n`, "utf8");
    await fs.rename(stageRoot, reportRoot);
    console.log(`已生成${cases.length}个发布案例的Helm交接材料`);
  } catch (error) {
    await fs.rm(stageRoot, { recursive: true, force: true });
    await fs.rm(reportRoot, { recursive: true, force: true });
    console.error(error.message);
    process.exitCode = 1;
  }
}

main();
