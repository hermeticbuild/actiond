#import <Foundation/NSArray.h>
#import <Foundation/NSError.h>
#import <Foundation/NSFileHandle.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>
#import <Virtualization/VZDiskImageStorageDeviceAttachment.h>
#import <Virtualization/VZFileHandleSerialPortAttachment.h>
#import <Virtualization/VZGenericPlatformConfiguration.h>
#import <Virtualization/VZLinuxBootLoader.h>
#import <Virtualization/VZSharedDirectory.h>
#import <Virtualization/VZSingleDirectoryShare.h>
#import <Virtualization/VZSocketDevice.h>
#import <Virtualization/VZVirtioBlockDeviceConfiguration.h>
#import <Virtualization/VZVirtioConsoleDeviceSerialPortConfiguration.h>
#import <Virtualization/VZVirtioEntropyDeviceConfiguration.h>
#import <Virtualization/VZVirtioFileSystemDeviceConfiguration.h>
#import <Virtualization/VZVirtioSocketConnection.h>
#import <Virtualization/VZVirtioSocketDevice.h>
#import <Virtualization/VZVirtioSocketDeviceConfiguration.h>
#import <Virtualization/VZVirtualMachine.h>
#import <Virtualization/VZVirtualMachineConfiguration.h>

#include <dispatch/dispatch.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

@interface ActiondVMHandle : NSObject
@property(nonatomic, strong) VZVirtualMachine *vm;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation ActiondVMHandle
@end

static void actiond_set_error(char *errbuf, size_t errbuf_len, NSString *message) {
    if (errbuf == NULL || errbuf_len == 0) return;
    const char *bytes = message.UTF8String;
    if (bytes == NULL) bytes = "unknown Virtualization.framework error";
    snprintf(errbuf, errbuf_len, "%s", bytes);
}

static void actiond_set_nserror(char *errbuf, size_t errbuf_len, NSError *error) {
    if (error == nil) {
        actiond_set_error(errbuf, errbuf_len, @"unknown Virtualization.framework error");
        return;
    }
    NSString *message = [NSString stringWithFormat:@"%@ (%@:%ld)",
                                                   error.localizedDescription,
                                                   error.domain,
                                                   (long)error.code];
    actiond_set_error(errbuf, errbuf_len, message);
}

static dispatch_time_t actiond_timeout_from_ms(uint32_t timeout_ms) {
    if (timeout_ms == 0) return DISPATCH_TIME_FOREVER;
    return dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * (int64_t)NSEC_PER_MSEC);
}

void *actiond_vm_start(
    const char *kernel_path,
    const char *initramfs_path,
    const char *runtime_image_path,
    const char *cas_path,
    const char *actiondfs_fstype,
    uint64_t memory_mib,
    uint32_t cpu_count,
    uint32_t start_timeout_ms,
    char *errbuf,
    size_t errbuf_len
) {
    @autoreleasepool {
        if (![VZVirtualMachine isSupported]) {
            actiond_set_error(errbuf, errbuf_len, @"Virtualization.framework is not supported on this host");
            return NULL;
        }

        NSURL *kernelURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:kernel_path]];
        NSURL *initramfsURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:initramfs_path]];
        NSURL *casURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:cas_path] isDirectory:YES];

        VZLinuxBootLoader *bootLoader = [[VZLinuxBootLoader alloc] initWithKernelURL:kernelURL];
        bootLoader.initialRamdiskURL = initramfsURL;
        NSString *actiondfsFSType = @"actiondfs";
        if (actiondfs_fstype != NULL && actiondfs_fstype[0] != '\0') {
            actiondfsFSType = [NSString stringWithUTF8String:actiondfs_fstype];
        }
        bootLoader.commandLine = [NSString stringWithFormat:
            @"console=hvc0 init=/init panic=-1 quiet actiond.actiondfs_fstype=%@",
            actiondfsFSType];

        VZSharedDirectory *casDirectory = [[VZSharedDirectory alloc] initWithURL:casURL readOnly:YES];
        VZSingleDirectoryShare *casShare = [[VZSingleDirectoryShare alloc] initWithDirectory:casDirectory];
        VZVirtioFileSystemDeviceConfiguration *casFs = [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:@"cas"];
        casFs.share = casShare;
        NSMutableArray<VZDirectorySharingDeviceConfiguration *> *directoryDevices =
            [NSMutableArray arrayWithObject:casFs];

        VZVirtualMachineConfiguration *configuration = [[VZVirtualMachineConfiguration alloc] init];
        configuration.bootLoader = bootLoader;
        configuration.platform = [[VZGenericPlatformConfiguration alloc] init];
        configuration.CPUCount = cpu_count == 0 ? 1 : (NSUInteger)cpu_count;
        configuration.memorySize = (memory_mib == 0 ? 512 : memory_mib) * 1024ULL * 1024ULL;
        configuration.entropyDevices = @[ [[VZVirtioEntropyDeviceConfiguration alloc] init] ];
        configuration.socketDevices = @[ [[VZVirtioSocketDeviceConfiguration alloc] init] ];
        configuration.networkDevices = @[];
        if (runtime_image_path != NULL && runtime_image_path[0] != '\0') {
            NSString *runtimePath = [NSString stringWithUTF8String:runtime_image_path];
            NSString *runtimeDirectoryPath = [runtimePath stringByDeletingLastPathComponent];
            NSURL *runtimeDirectoryURL = [NSURL fileURLWithPath:runtimeDirectoryPath isDirectory:YES];
            VZSharedDirectory *runtimeDirectory = [[VZSharedDirectory alloc] initWithURL:runtimeDirectoryURL readOnly:YES];
            VZSingleDirectoryShare *runtimeShare = [[VZSingleDirectoryShare alloc] initWithDirectory:runtimeDirectory];
            VZVirtioFileSystemDeviceConfiguration *runtimeFs =
                [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:@"runtimes"];
            runtimeFs.share = runtimeShare;
            [directoryDevices addObject:runtimeFs];

            NSURL *runtimeURL = [NSURL fileURLWithPath:runtimePath];
            NSError *runtimeError = nil;
            VZDiskImageStorageDeviceAttachment *runtimeAttachment =
                [[VZDiskImageStorageDeviceAttachment alloc] initWithURL:runtimeURL readOnly:YES error:&runtimeError];
            if (runtimeAttachment == nil) {
                actiond_set_nserror(errbuf, errbuf_len, runtimeError);
                return NULL;
            }
            VZVirtioBlockDeviceConfiguration *runtimeBlock =
                [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:runtimeAttachment];
            configuration.storageDevices = @[ runtimeBlock ];
        }
        configuration.directorySharingDevices = directoryDevices;

        VZVirtioConsoleDeviceSerialPortConfiguration *serial = [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
        serial.attachment = [[VZFileHandleSerialPortAttachment alloc]
            initWithFileHandleForReading:nil
                    fileHandleForWriting:[NSFileHandle fileHandleWithStandardError]];
        configuration.serialPorts = @[ serial ];

        NSError *validationError = nil;
        if (![configuration validateWithError:&validationError]) {
            actiond_set_nserror(errbuf, errbuf_len, validationError);
            return NULL;
        }

        ActiondVMHandle *handle = [[ActiondVMHandle alloc] init];
        handle.queue = dispatch_queue_create("dev.actiond.vm", DISPATCH_QUEUE_SERIAL);
        handle.vm = [[VZVirtualMachine alloc] initWithConfiguration:configuration queue:handle.queue];

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block NSError *startError = nil;
        dispatch_async(handle.queue, ^{
            [handle.vm startWithCompletionHandler:^(NSError *errorOrNil) {
                startError = errorOrNil;
                dispatch_semaphore_signal(semaphore);
            }];
        });

        if (dispatch_semaphore_wait(semaphore, actiond_timeout_from_ms(start_timeout_ms)) != 0) {
            actiond_set_error(errbuf, errbuf_len, @"timed out starting virtual machine");
            return NULL;
        }
        if (startError != nil) {
            actiond_set_nserror(errbuf, errbuf_len, startError);
            return NULL;
        }

        return (__bridge_retained void *)handle;
    }
}

int actiond_vm_connect(
    void *raw_handle,
    uint32_t port,
    uint32_t timeout_ms,
    char *errbuf,
    size_t errbuf_len
) {
    if (raw_handle == NULL) {
        actiond_set_error(errbuf, errbuf_len, @"missing VM handle");
        return -1;
    }

    ActiondVMHandle *handle = (__bridge ActiondVMHandle *)raw_handle;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block int result_fd = -1;
    __block NSError *connectError = nil;
    __block NSString *failure = nil;

    dispatch_async(handle.queue, ^{
        NSArray<VZSocketDevice *> *socketDevices = handle.vm.socketDevices;
        if (socketDevices.count == 0 || ![socketDevices[0] isKindOfClass:[VZVirtioSocketDevice class]]) {
            failure = @"virtual machine has no virtio socket device";
            dispatch_semaphore_signal(semaphore);
            return;
        }

        VZVirtioSocketDevice *socketDevice = (VZVirtioSocketDevice *)socketDevices[0];
        [socketDevice connectToPort:port completionHandler:^(VZVirtioSocketConnection *connection, NSError *errorOrNil) {
            connectError = errorOrNil;
            if (connection != nil) {
                int fd = connection.fileDescriptor;
                if (fd >= 0) {
                    result_fd = dup(fd);
                    if (result_fd < 0) {
                        failure = [NSString stringWithFormat:@"dup(vsock fd) failed: %s", strerror(errno)];
                    }
                } else {
                    failure = @"virtio socket connection returned an invalid file descriptor";
                }
                [connection close];
            }
            dispatch_semaphore_signal(semaphore);
        }];
    });

    if (dispatch_semaphore_wait(semaphore, actiond_timeout_from_ms(timeout_ms)) != 0) {
        actiond_set_error(errbuf, errbuf_len, @"timed out connecting to guest vsock port");
        return -1;
    }
    if (connectError != nil) {
        actiond_set_nserror(errbuf, errbuf_len, connectError);
        return -1;
    }
    if (failure != nil) {
        actiond_set_error(errbuf, errbuf_len, failure);
        return -1;
    }
    if (result_fd < 0) {
        actiond_set_error(errbuf, errbuf_len, @"guest vsock connection failed");
        return -1;
    }
    return result_fd;
}

void actiond_vm_stop(void *raw_handle) {
    if (raw_handle == NULL) return;
    ActiondVMHandle *handle = (__bridge ActiondVMHandle *)raw_handle;
    dispatch_async(handle.queue, ^{
        if (handle.vm.canStop) {
            [handle.vm stopWithCompletionHandler:^(NSError *errorOrNil) {
                (void)errorOrNil;
            }];
        }
    });
}

void actiond_vm_release(void *raw_handle) {
    if (raw_handle == NULL) return;
    CFRelease(raw_handle);
}
