# 特征封账控制器HelmChart交付

本仓库保存特征平台封账控制器的业务输入与完成Chart。input_data包含资产合同、发布清单、三份命名空间配置与处理入口，candidate/chart保存完成Chart。

业务入口：

    cd input_data
    npm ci
    npm run process

入口在同级output目录写出完成Chart与五份发布交接文件。业务要求和交付规则位于task目录。
