#import "SPKStrings.h"
#import "SPKShareBlocklistViewController.h"

#import "../Shared/Messages/SPKShareBlocklistManager.h"

@implementation SPKShareBlocklistViewController {
    NSArray<NSString *> *_usernames;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SPKL(@"GENERAL_SHARE_BLOCKLIST_TITLE");
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(_promptAdd)];
    [self _reload];
}

- (void)_reload {
    _usernames = [SPKShareBlocklistManager shared].blockedUsernames;
    [self.tableView reloadData];
}

- (void)_promptAdd {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:SPKL(@"GENERAL_SHARE_BLOCKLIST_ADD_TITLE")
                                                               message:SPKL(@"GENERAL_SHARE_BLOCKLIST_ADD_MESSAGE")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = SPKL(@"GENERAL_SHARE_BLOCKLIST_ADD_PLACEHOLDER");
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:SPKL(@"GENERAL_SHARE_BLOCKLIST_BLOCK")
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        NSString *val = ac.textFields.firstObject.text;
        if (val.length) {
            [[SPKShareBlocklistManager shared] blockUsername:val];
            [self _reload];
        }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return _usernames.count ?: 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:SPKL(@"GENERAL_SHARE_BLOCKLIST_HEADER_FORMAT"), (unsigned long)_usernames.count];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    return SPKL(@"GENERAL_SHARE_BLOCKLIST_FOOTER");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"cell" forIndexPath:ip];
    if (!_usernames.count) {
        cell.textLabel.text = SPKL(@"GENERAL_SHARE_BLOCKLIST_EMPTY");
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.userInteractionEnabled = NO;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    cell.textLabel.text = [NSString stringWithFormat:@"@%@", _usernames[ip.row]];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.userInteractionEnabled = YES;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return _usernames.count > 0;
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete) {
        [[SPKShareBlocklistManager shared] unblockUsername:_usernames[ip.row]];
        [self _reload];
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_usernames.count)
        return;

    NSString *username = _usernames[ip.row];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"@%@", username]
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:SPKL(@"GENERAL_SHARE_BLOCKLIST_UNBLOCK")
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        [[SPKShareBlocklistManager shared] unblockUsername:username];
        [self _reload];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:SPKL(@"GENERAL_SHARE_BLOCKLIST_COPY")
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = username;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:SPKL(@"ALERT_ACTION_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) {
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        ac.popoverPresentationController.sourceView = cell;
        ac.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:ac animated:YES completion:nil];
}

@end
