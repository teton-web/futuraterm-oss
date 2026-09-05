#import "ObjCExceptionCatcher.h"

NSException *FuturaTermCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
