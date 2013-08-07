//
//  Created by marco on 10/07/13.
//
//
//


#import <objc/runtime.h>
#import "NimbleStore.h"
#import "NimbleStore+Defaults.h"
#import "NSManagedObjectContext+NimbleContexts.h"


@interface NimbleStore ()
@property(strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property(strong, nonatomic) NSManagedObjectContext *mainContext;
@property(strong, nonatomic) NSManagedObjectContext *backgroundContext;
@property(strong, nonatomic) NSOperationQueue *queueForBackgroundSavings;
@end

static NimbleStore *mainStore;

@implementation NimbleStore

#pragma mark - Setup store

+ (void)nb_setupStore
{
  [self nb_setupStoreWithFilename:[self.class nb_defaultStoreName]];
}

+ (void)nb_setupStoreWithFilename:(NSString *)filename
{
  NSParameterAssert(filename);
  [self setupStoreWithName:filename storeType:NSSQLiteStoreType];
}

+ (void)nb_setupInMemoryStore
{
  [self setupStoreWithName:nil storeType:NSInMemoryStoreType];
}

+ (void)setupStoreWithName:(NSString *)filename storeType:(NSString * const)storeType
{
  [self setupStoreWithName:filename storeType:storeType iCloudEnabled:NO options:nil ];
}

+ (void)nb_setup_iCloudStore
{
  // cloud URL
  NSURL *URLForUbiquityContainerIdentifier = [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:nil];
  NSString* coreDataCloudContent = [[URLForUbiquityContainerIdentifier path] stringByAppendingPathComponent:[self.class nb_defaultStoreName]];
  NSURL *cloudURL = [NSURL fileURLWithPath:coreDataCloudContent];

  // container id
  NSString *containerID = [[[NSBundle mainBundle] infoDictionary] objectForKey:(id)kCFBundleIdentifierKey];

  // content name key
  NSString *contentNameKey = [NSString stringWithFormat:@"%@.%@", containerID, [self.class nb_defaultStoreName]];

  [self nb_setup_iCloudStoreWithCloudURL:cloudURL localStoreNamed:[self.class nb_defaultStoreName] containerID:containerID contentNameKey:contentNameKey];
}

+ (void)nb_setup_iCloudStoreWithCloudURL:(NSURL *)cloudURL localStoreNamed:(NSString *)localStoreName containerID:(NSString *)containerID contentNameKey:(NSString *)contentNameKey
{
  NSDictionary *iCloudOptions = @{
    NSPersistentStoreUbiquitousContentNameKey : contentNameKey,
    NSPersistentStoreUbiquitousContentURLKey : cloudURL,
    NSMigratePersistentStoresAutomaticallyOption : @(YES),
    NSInferMappingModelAutomaticallyOption : @(YES),
//    NSPersistentStoreUbiquitousContainerIdentifierKey : containerID,
//    NSPersistentStoreRebuildFromUbiquitousContentOption : @YES,
//    NSPersistentStoreRemoveUbiquitousMetadataOption: @YES
  };
  [self setupStoreWithName:localStoreName storeType:NSSQLiteStoreType iCloudEnabled:YES options:iCloudOptions];
}

#pragma mark - Private main initializer

+ (void)setupStoreWithName:(NSString *)filename storeType:(NSString * const)storeType iCloudEnabled:(BOOL)iCloudEnabled options:(NSDictionary *)options
{
  NSAssert(!mainStore, @"Store already was already set up", nil);

  mainStore = [[NimbleStore alloc] init];

  NSManagedObjectModel *model = [NSManagedObjectModel mergedModelFromBundles:nil];
  mainStore.persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSAssert(mainStore.persistentStoreCoordinator, @"Error creating persistent store coordinator", nil);

  NSString *fileURL = [NSString localizedStringWithFormat:@"%@/%@", [self.class nb_applicationDocumentsDirectory], filename];
  NSURL *localStoreURL = [NSURL fileURLWithPath:fileURL];

  [mainStore.persistentStoreCoordinator lock];
  NSError *error;
  [mainStore.persistentStoreCoordinator addPersistentStoreWithType:storeType
                                                     configuration:nil
                                                               URL:localStoreURL
                                                           options:options
                                                             error:&error];
  NSAssert(!error, @"Error initializing the store %@", error);
  [mainStore.persistentStoreCoordinator unlock];

  mainStore.mainContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  mainStore.backgroundContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  [mainStore.mainContext setPersistentStoreCoordinator:mainStore.persistentStoreCoordinator];
  [mainStore.backgroundContext setPersistentStoreCoordinator:mainStore.persistentStoreCoordinator];

  mainStore.queueForBackgroundSavings = [[NSOperationQueue alloc] init];
  mainStore.queueForBackgroundSavings.maxConcurrentOperationCount = 1;

  // register observer to merge contexts
  [[NSNotificationCenter defaultCenter] addObserver:mainStore
                                           selector:@selector(contextDidSave:)
                                               name:NSManagedObjectContextDidSaveNotification
                                             object:mainStore.backgroundContext];

  if (iCloudEnabled) {
//    [[NSNotificationCenter defaultCenter] addObserver:self
//                                             selector:@selector(storeWillChangeFrom_iCloud:)
//                                                 name:NSPersistentStoreCoordinatorStoresWillChangeNotification
//                                               object:mainStore.persistentStoreCoordinator];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(mergeChangesFrom_iCloud:)
                                                 name:NSPersistentStoreDidImportUbiquitousContentChangesNotification
                                               object:mainStore.persistentStoreCoordinator];
  }
}

#pragma mark - Fetch request

+ (NSArray *)nb_executeFetchRequest:(NSFetchRequest *)request inContextOfType:(NimbleContextType)contextType
{
  NSParameterAssert(request);

  return [[NSManagedObjectContext nb_contextForType:contextType] executeFetchRequest:request error:nil];
}

#pragma mark - Contexts

+ (NSManagedObjectContext *)nb_mainContext
{
  return mainStore.mainContext;
}

+ (NSManagedObjectContext *)nb_backgroundContext
{
  return mainStore.backgroundContext;
}

#pragma mark - Notifications

- (void)contextDidSave:(NSNotification *)notification
{
  [self.mainContext performBlock:^{
    [self.mainContext mergeChangesFromContextDidSaveNotification:notification];
  }];
}

- (void)mergeChangesFrom_iCloud:(NSNotification *)notification
{
  [self.mainContext performBlock:^{
    [self.mainContext mergeChangesFromContextDidSaveNotification:notification];
  }];
}

- (void)storeWillChangeFrom_iCloud:(NSNotification *)storeWillChangeFromiCloud
{
  if ([mainStore.mainContext hasChanges]) {
    [mainStore.mainContext save:nil];
  }
  [mainStore.mainContext reset];
  //reset user interface
}



#pragma mark - Background saving queue

+ (NSOperationQueue *)nb_queueForBackgroundSavings
{
  return mainStore.queueForBackgroundSavings;
}

#pragma mark - Dealloc

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:mainStore];
}

@end