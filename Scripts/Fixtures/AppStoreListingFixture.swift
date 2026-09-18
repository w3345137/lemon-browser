/// 占位编译单元：swiftc 单文件 + @main 会误判存在顶层代码，
/// TestSandboxEntitlements 需要至少两个输入文件才能编译。
enum AppStoreListingFixture {}
