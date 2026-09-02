/*
    MesIngest 部署的一次性 SQL Server 授权
    目标实例：WIN-0HD72AV4K31 上的 MSSQLSERVER（SQL Server 2022 Developer）

    ── 这个脚本做什么 ────────────────────────────────────────────────
    把本地管理员账号 agvops 加成 SQL Server 登录，并只给它两项服务器级权限：

      dbcreator       建 MesIngest 库（建完自动成为该库 owner）
      ALTER ANY LOGIN 建 mesingest 这个专用应用登录

    之后 SSH 通道（以 agvops 身份）就能自己完成建库和建登录，CD 不需要再向你
    要一次 sysadmin。

    ── 这个脚本不做什么 ──────────────────────────────────────────────
    不给 sysadmin。不给 securityadmin。不碰 SQAGV，一行都不碰。

    ── 你要知道的风险 ────────────────────────────────────────────────
    ALTER ANY LOGIN 是一条已知的提权路径：拿到它的人可以改别的 SQL 登录的密码，
    包括 sa。也就是说，任何拿到控制端那把 agv_srv_ed25519 私钥的人，理论上顺着
    这条路能碰到同实例上的 SQAGV 生产库。

    这个取舍你已经拍板过（CD 走 SSH 自助建库，而不是每次找你提权）。如果哪天想
    收回来，把这两项 REVOKE 掉即可，脚本末尾有对应语句（注释状态）。

    ── 怎么执行 ─────────────────────────────────────────────────────
    用 Navicat 或 SSMS 以 sysadmin 身份连 WIN-0HD72AV4K31，整段执行一次。
    脚本是幂等的，重复执行不会报错也不会重复授权。
*/

SET NOCOUNT ON;
GO

DECLARE @login sysname = N'WIN-0HD72AV4K31\agvops';

------------------------------------------------------------------------
-- 1. Windows 登录
------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    DECLARE @createLogin nvarchar(max) =
        N'CREATE LOGIN ' + QUOTENAME(@login) + N' FROM WINDOWS;';
    EXEC sp_executesql @createLogin;
    PRINT N'已创建登录：' + @login;
END
ELSE
    PRINT N'登录已存在，跳过：' + @login;
GO

------------------------------------------------------------------------
-- 2. dbcreator：允许建 MesIngest 库
------------------------------------------------------------------------
DECLARE @login sysname = N'WIN-0HD72AV4K31\agvops';

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_role_members rm
        JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
        JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'dbcreator' AND m.name = @login)
BEGIN
    DECLARE @addRole nvarchar(max) =
        N'ALTER SERVER ROLE [dbcreator] ADD MEMBER ' + QUOTENAME(@login) + N';';
    EXEC sp_executesql @addRole;
    PRINT N'已授予 dbcreator';
END
ELSE
    PRINT N'dbcreator 已在，跳过';
GO

------------------------------------------------------------------------
-- 3. ALTER ANY LOGIN：允许建 mesingest 应用登录
------------------------------------------------------------------------
DECLARE @login sysname = N'WIN-0HD72AV4K31\agvops';
DECLARE @grant nvarchar(max) =
    N'GRANT ALTER ANY LOGIN TO ' + QUOTENAME(@login) + N';';
EXEC sp_executesql @grant;
PRINT N'已授予 ALTER ANY LOGIN（GRANT 本身幂等）';
GO

------------------------------------------------------------------------
-- 4. 核对结果
------------------------------------------------------------------------
SELECT
    sp.name                                   AS [登录],
    sp.type_desc                              AS [类型],
    sp.is_disabled                            AS [已禁用],
    IS_SRVROLEMEMBER(N'sysadmin',  sp.name)   AS [sysadmin],
    IS_SRVROLEMEMBER(N'dbcreator', sp.name)   AS [dbcreator],
    IS_SRVROLEMEMBER(N'securityadmin', sp.name) AS [securityadmin]
FROM sys.server_principals sp
WHERE sp.name = N'WIN-0HD72AV4K31\agvops';

SELECT
    p.permission_name AS [服务器级权限],
    p.state_desc      AS [状态]
FROM sys.server_permissions p
    JOIN sys.server_principals sp ON sp.principal_id = p.grantee_principal_id
WHERE sp.name = N'WIN-0HD72AV4K31\agvops'
ORDER BY p.permission_name;
GO

/*
    预期结果：sysadmin = 0，securityadmin = 0，dbcreator = 1，
    服务器级权限里有 CONNECT SQL 和 ALTER ANY LOGIN。

    ── 收回授权（需要时取消注释执行）────────────────────────────────
    REVOKE ALTER ANY LOGIN FROM [WIN-0HD72AV4K31\agvops];
    ALTER SERVER ROLE [dbcreator] DROP MEMBER [WIN-0HD72AV4K31\agvops];
    -- 彻底收回连登录一起删（会让 CD 的建库步骤失效）：
    -- DROP LOGIN [WIN-0HD72AV4K31\agvops];
*/
