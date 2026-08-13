# 特征封账控制器Chart交付

policy/asset_contract.json记录资产合同、最小权限、网络边界和发布Hook规则。cases/render_cases.csv与三份values文件记录预览、生产和强监管发布案例，starter/feature-freeze-control是待完成Chart骨架。

完成后的Chart放在output/chart/feature-freeze-control。确认Helm与Node.js可用后，在input_data目录执行：

    npm run process

入口逐个处理发布案例，调用helm lint与helm template，再从渲染对象导出对象清单、权限清单、网络边界、Hook顺序和发布交接记录。Helm只读取本地Chart、合同和values文件，不连接Kubernetes集群。

平台发布人员使用对象清单安排命名空间变更，安全人员复核权限清单，网络团队核对边界清单，特征治理人员依据Hook顺序和发布交接记录安排封账窗口。
