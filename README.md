# 特征封账控制器HelmChart交付

本仓库保存特征平台封账控制器的业务输入、完成Chart和题面镜像。`input_data`包含资产合同、发布清单、三份命名空间配置与处理入口，`candidate/chart`是待交付的完成Chart。

业务入口：

    cd input_data
    npm ci
    npm run process

入口在同级`output`写出完成Chart与五份发布交接文件。任务要求和评分规则位于`task`目录。
