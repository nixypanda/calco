module Translations.HiIn exposing (hiInTranslations)

import Translations.Ids exposing (TranslationId(..))


hiInTranslations : TranslationId -> String
hiInTranslations tid =
    case tid of
        TidApiErrorBadBody ->
            "सर्वर ने एक अप्रत्याशित प्रतिक्रिया लौटाई। पृष्ठ को रीफ़्रेश करें और दोबारा प्रयास करें।"

        TidApiErrorBadUrl ->
            "सर्वर से कनेक्ट नहीं हो सका। पृष्ठ को रीफ़्रेश करें और दोबारा प्रयास करें।"

        TidApiErrorNetwork ->
            "सर्वर तक पहुँच नहीं सका। अपना कनेक्शन जाँचें और दोबारा प्रयास करें।"

        TidApiErrorRateLimited ->
            "बहुत अधिक अनुरोध। कृपया दोबारा प्रयास करने से पहले प्रतीक्षा करें।"

        TidApiErrorRateLimitedSeconds hole0 ->
            "बहुत अधिक अनुरोध। " ++ hole0 ++ " सेकंड में दोबारा प्रयास करें।"

        TidApiErrorServer ->
            "सर्वर अनुरोध पूरा नहीं कर सका। दोबारा प्रयास करें।"

        TidApiErrorTimeout ->
            "सर्वर ने उत्तर देने में बहुत समय लिया। दोबारा प्रयास करें।"

        TidApiKeysConfirmRevoke ->
            "कुंजी रद्द करें"

        TidApiKeysCopied ->
            "कॉपी हो गई"

        TidApiKeysCopy ->
            "कॉपी करें"

        TidApiKeysCopyAria ->
            "API कुंजी को क्लिपबोर्ड में कॉपी करें"

        TidApiKeysCopyFailed ->
            "कॉपी नहीं हो सकी — कुंजी को मैन्युअल रूप से चुनें।"

        TidApiKeysCopying ->
            "कॉपी की जा रही है…"

        TidApiKeysCreate ->
            "API कुंजी बनाएँ"

        TidApiKeysCreateDescription ->
            "कुंजी को ऐसा नाम दें जिससे आप उसे बाद में पहचान सकें।"

        TidApiKeysCreateTitle ->
            "API कुंजी बनाएँ"

        TidApiKeysCreatedOn hole0 ->
            hole0 ++ " को बनाया गया"

        TidApiKeysCreatedTitle ->
            "API कुंजी बन गई"

        TidApiKeysCreatedWarning ->
            "इस कुंजी को अभी कॉपी करें। यह दोबारा नहीं दिखाई जाएगी।"

        TidApiKeysDescription ->
            "API कुंजियाँ स्क्रिप्ट और टूल को आपका डेटा एक्सेस करने देती हैं। इन्हें पासवर्ड की तरह संभालें।"

        TidApiKeysDetails ->
            "कुंजी विवरण"

        TidApiKeysDone ->
            "हो गया"

        TidApiKeysEmpty ->
            "आपके पास अभी कोई API कुंजी नहीं है।"

        TidApiKeysExpires hole0 ->
            hole0 ++ " को समाप्त होगी"

        TidApiKeysExpiry ->
            "समाप्ति"

        TidApiKeysExpiry30Days ->
            "30 दिन"

        TidApiKeysExpiry365Days ->
            "1 वर्ष"

        TidApiKeysExpiry90Days ->
            "90 दिन"

        TidApiKeysExpiryNever ->
            "कभी नहीं"

        TidApiKeysHint hole0 ->
            "कुंजी संकेत: " ++ hole0

        TidApiKeysLastUsed hole0 ->
            "अंतिम बार " ++ hole0 ++ " को उपयोग"

        TidApiKeysName ->
            "नाम"

        TidApiKeysNameInvalid ->
            "नाम में असमर्थित वर्ण हैं।"

        TidApiKeysNameRequired ->
            "नाम आवश्यक है।"

        TidApiKeysNameTooLong ->
            "नाम 64 वर्णों या उससे कम होना चाहिए।"

        TidApiKeysNeverExpires ->
            "कभी समाप्त नहीं होगी"

        TidApiKeysNeverUsed ->
            "कभी उपयोग नहीं हुई"

        TidApiKeysRevoke ->
            "रद्द करें"

        TidApiKeysRevokeDescription hole0 hole1 ->
            hole0 ++ " (" ++ hole1 ++ ") का उपयोग करने वाली हर चीज़ तुरंत काम करना बंद कर देगी।"

        TidApiKeysRevokeNamed hole0 ->
            hole0 ++ " रद्द करें"

        TidApiKeysRevokeTitle ->
            "API कुंजी रद्द करें?"

        TidApiKeysRevoking ->
            "रद्द की जा रही है..."

        TidApiKeysScope ->
            "दायरा"

        TidApiKeysScopeRead ->
            "केवल पढ़ें"

        TidApiKeysScopeReadDescription ->
            "आपकी डायरी, खाद्य पदार्थ, भोजन, लक्ष्य और प्राथमिकताएँ पढ़ सकती है।"

        TidApiKeysScopeReadWrite ->
            "पढ़ें और लिखें"

        TidApiKeysScopeReadWriteDescription ->
            "आपकी डायरी, खाद्य पदार्थ, भोजन, लक्ष्य और प्राथमिकताएँ पढ़ और बदल सकती है।"

        TidApiKeysScopeUnknown ->
            "अज्ञात दायरा"

        TidApiKeysSecretLabel ->
            "API कुंजी गोपनीय मान"

        TidApiKeysUsage ->
            "इसे Authorization हेडर में भेजें:"

        TidApiKeysUsageExample ->
            "Authorization: Bearer <your API key>"

        TidAssistantApplyReplacesForm ->
            "इस ड्राफ़्ट को लागू करने से फ़ॉर्म में पहले से मौजूद मान बदल जाएँगे।"

        TidAssistantApplyToForm ->
            "फ़ॉर्म पर लागू करें"

        TidAssistantApplying ->
            "लागू किया जा रहा है…"

        TidAssistantAskForChanges ->
            "बदलाव के लिए कहें"

        TidAssistantBusy ->
            "सहायक व्यस्त है। थोड़ी देर प्रतीक्षा करें, फिर दोबारा प्रयास करें।"

        TidAssistantCancelChanges ->
            "बदलाव रद्द करें"

        TidAssistantChangesLabel ->
            "क्या बदलना चाहिए?"

        TidAssistantChangesPlaceholder ->
            "उदाहरण: 250 g का उपयोग करें और तेल कम करें"

        TidAssistantChooseMorePhotos ->
            "और फ़ोटो चुनें"

        TidAssistantChoosePhotos ->
            "फ़ोटो चुनें"

        TidAssistantConversation ->
            "बातचीत"

        TidAssistantConversationEmpty ->
            "बातचीत में एक संदेश होना चाहिए।"

        TidAssistantConversationFull ->
            "यह बातचीत भर गई है। नया सहायक सत्र शुरू करें।"

        TidAssistantConversationMessageRequired ->
            "बातचीत का संदेश आवश्यक है।"

        TidAssistantConversationMessageTooLong ->
            "बातचीत के संदेश 4,000 वर्णों या उससे कम होने चाहिए।"

        TidAssistantDefaultQuantity ->
            "डिफ़ॉल्ट मात्रा"

        TidAssistantDescriptionLabel ->
            "भोजन का विवरण या उत्तर"

        TidAssistantDescriptionPlaceholder ->
            "उदाहरण: एक कटोरी दाल, लगभग 300 g"

        TidAssistantDraftFailed ->
            "सहायक ड्राफ़्ट नहीं बना सका। कृपया दोबारा प्रयास करें।"

        TidAssistantDraftPreview ->
            "ड्राफ़्ट पूर्वावलोकन"

        TidAssistantEstimateFood ->
            "भोजन का अनुमान लगाएँ"

        TidAssistantEstimateNotes ->
            "अनुमान की टिप्पणियाँ"

        TidAssistantEstimatePrefix hole0 ->
            "अनुमान: " ++ hole0

        TidAssistantGeneratingDraft ->
            "ड्राफ़्ट बनाया जा रहा है…"

        TidAssistantHideAdditionalNutrients ->
            "अतिरिक्त पोषक तत्व छिपाएँ"

        TidAssistantLoadingPreview ->
            "पूर्वावलोकन लोड हो रहा है…"

        TidAssistantNetworkError ->
            "सहायक तक पहुँच नहीं हो सकी। अपना कनेक्शन जाँचें और दोबारा प्रयास करें।"

        TidAssistantNewSession ->
            "नया सत्र"

        TidAssistantNoNutrientsSuggested ->
            "कोई सुझाव नहीं।"

        TidAssistantNutritionPer100g ->
            "प्रति 100 g पोषण"

        TidAssistantPhotoLimit ->
            "केवल चार फ़ोटो संलग्न की जा सकती हैं।"

        TidAssistantPhotoTooLarge ->
            "प्रत्येक फ़ोटो 15 MiB या उससे छोटी होनी चाहिए।"

        TidAssistantPhotoTypes ->
            "फ़ोटो JPEG, PNG या WebP प्रारूप में होनी चाहिए।"

        TidAssistantPhotosMax ->
            "चार फ़ोटो संलग्न (अधिकतम)।"

        TidAssistantPhotosOptional ->
            "फ़ोटो (वैकल्पिक)"

        TidAssistantPhotosTotalTooLarge ->
            "फ़ोटो मिलकर 40 MiB या उससे छोटी होनी चाहिए।"

        TidAssistantRateLimitedRetry hole0 ->
            "सहायक व्यस्त है। " ++ hole0 ++ " सेकंड में दोबारा प्रयास करें।"

        TidAssistantRemovePhoto ->
            "फ़ोटो हटाएँ"

        TidAssistantReplaceFormValues ->
            "फ़ॉर्म के मान बदलें"

        TidAssistantRetryLastRequest ->
            "पिछला अनुरोध दोबारा भेजें"

        TidAssistantRetryStatusCheck ->
            "उपलब्धता जाँच दोबारा करें"

        TidAssistantReviewEstimate ->
            "अनुमान की समीक्षा करें"

        TidAssistantReviewEstimatePrefix hole0 ->
            "अनुमान की समीक्षा करें: " ++ hole0

        TidAssistantReviewFoodEstimate ->
            "भोजन अनुमान की समीक्षा करें"

        TidAssistantReviewNutritionTotalsNote ->
            "पोषण मान आपके द्वारा दर्ज किए जा रहे पूरे हिस्से के कुल मान हैं।"

        TidAssistantRoleAssistant ->
            "CalCo सहायक"

        TidAssistantRoleUser ->
            "आप"

        TidAssistantSend ->
            "भेजें"

        TidAssistantServingConversion hole0 hole1 ->
            "1 " ++ hole0 ++ " = " ++ hole1 ++ " g"

        TidAssistantSessionExpired ->
            "आपका सत्र समाप्त हो गया है।"

        TidAssistantShowAdditionalNutrients ->
            "अतिरिक्त पोषक तत्व दिखाएँ"

        TidAssistantStartNewSession ->
            "नया सत्र शुरू करें"

        TidAssistantStartNewSessionBody ->
            "मौजूदा बातचीत और ड्राफ़्ट हटा दिए जाएँगे। आपका भोजन फ़ॉर्म नहीं बदलेगा।"

        TidAssistantStartNewSessionTitle ->
            "नया सत्र शुरू करें?"

        TidAssistantStatusCheckFailed ->
            "भोजन-सहायक की उपलब्धता की जाँच नहीं हो सकी।"

        TidAssistantTakePhoto ->
            "फ़ोटो लें"

        TidAssistantTakePhotoAria ->
            "भोजन की फ़ोटो लें"

        TidAssistantTimeout ->
            "सहायक ने उत्तर देने में बहुत समय लिया। कृपया दोबारा प्रयास करें।"

        TidAssistantUnavailable ->
            "इस परिनियोजन पर भोजन सहायता उपलब्ध नहीं है।"

        TidCalendarMonthApril ->
            "अप्रैल"

        TidCalendarMonthAugust ->
            "अगस्त"

        TidCalendarMonthDecember ->
            "दिसंबर"

        TidCalendarMonthFebruary ->
            "फ़रवरी"

        TidCalendarMonthJanuary ->
            "जनवरी"

        TidCalendarMonthJuly ->
            "जुलाई"

        TidCalendarMonthJune ->
            "जून"

        TidCalendarMonthMarch ->
            "मार्च"

        TidCalendarMonthMay ->
            "मई"

        TidCalendarMonthNovember ->
            "नवंबर"

        TidCalendarMonthOctober ->
            "अक्टूबर"

        TidCalendarMonthSeptember ->
            "सितंबर"

        TidCalendarMonthYear hole0 hole1 ->
            hole0 ++ " " ++ hole1

        TidCommonCancel ->
            "रद्द करें"

        TidCommonClose ->
            "बंद करें"

        TidCommonCreated ->
            "बनाया गया"

        TidCommonCreating ->
            "बनाया जा रहा है..."

        TidCommonDisplayName ->
            "प्रदर्शित नाम"

        TidCommonLoading ->
            "लोड हो रहा है..."

        TidCommonNewVersionAvailable ->
            "नया संस्करण उपलब्ध है"

        TidCommonNoneSuggested ->
            "कोई सुझाव नहीं"

        TidCommonNotSpecified ->
            "निर्दिष्ट नहीं"

        TidCommonPassword ->
            "पासवर्ड"

        TidCommonProfile ->
            "प्रोफ़ाइल"

        TidCommonRouteNotMigrated ->
            "यह रूट अभी स्थानांतरित नहीं हुआ है।"

        TidCommonSave ->
            "सहेजें"

        TidCommonSaving ->
            "सहेजा जा रहा है..."

        TidCommonSignedIn ->
            "साइन इन किया गया"

        TidCommonSignedInAs hole0 ->
            hole0 ++ " के रूप में साइन इन"

        TidCommonStatus ->
            "स्थिति"

        TidCommonTapToRefresh ->
            "रीफ़्रेश करने के लिए टैप करें"

        TidCommonUseDarkTheme ->
            "डार्क थीम का उपयोग करें"

        TidCommonUsername ->
            "उपयोगकर्ता नाम"

        TidCommonUsernameRequired ->
            "उपयोगकर्ता नाम आवश्यक है"

        TidCustomFoodConfirmDelete ->
            "हटाने की पुष्टि करें"

        TidCustomFoodDelete ->
            "खाद्य पदार्थ हटाएँ"

        TidCustomFoodDeleteConfirmDescription ->
            "यह कस्टम खाद्य पदार्थ स्थायी रूप से हटा दिया जाएगा।"

        TidCustomFoodDeleteConfirmTitle ->
            "खाद्य पदार्थ हटाएँ?"

        TidCustomFoodDeleting ->
            "हटाया जा रहा है..."

        TidCustomFoodDuplicateServingUnit hole0 ->
            "प्रत्येक सर्विंग के लिए अनोखी इकाई होनी चाहिए (डुप्लिकेट: " ++ hole0 ++ ")"

        TidCustomFoodEnterManually ->
            "मैन्युअल रूप से दर्ज करें"

        TidCustomFoodInvalidDefaultPortion ->
            "डिफ़ॉल्ट हिस्सा ग्राम में होना चाहिए या कॉन्फ़िगर की गई सर्विंग इकाई का उपयोग करना चाहिए"

        TidCustomFoodInvalidNutrientAmount hole0 ->
            "पोषक तत्व की मात्रा एक गैर-ऋणात्मक संख्या होनी चाहिए (प्राप्त: " ++ hole0 ++ ")"

        TidCustomFoodInvalidServingGrams hole0 ->
            "प्रति सर्विंग इकाई ग्राम एक धनात्मक संख्या होनी चाहिए (प्राप्त: " ++ hole0 ++ ")"

        TidCustomFoodListEmpty ->
            "अभी कोई आइटम नहीं।"

        TidCustomFoodNameRequired ->
            "नाम आवश्यक है"

        TidCustomFoodSave ->
            "खाद्य पदार्थ सहेजें"

        TidDateMonthApr ->
            "अप्रै"

        TidDateMonthAug ->
            "अग"

        TidDateMonthDec ->
            "दिस"

        TidDateMonthFeb ->
            "फ़र"

        TidDateMonthJan ->
            "जन"

        TidDateMonthJul ->
            "जुल"

        TidDateMonthJun ->
            "जून"

        TidDateMonthMar ->
            "मार्च"

        TidDateMonthMay ->
            "मई"

        TidDateMonthNov ->
            "नव"

        TidDateMonthOct ->
            "अक्ट"

        TidDateMonthSep ->
            "सित"

        TidDiaryAddFood ->
            "+ भोजन जोड़ें"

        TidDiaryCalendarDayAriaLogged hole0 hole1 ->
            hole0 ++ ", " ++ hole1 ++ " किलोकैलोरी दर्ज"

        TidDiaryCalendarDayAriaNoFood hole0 ->
            hole0 ++ ", कोई भोजन दर्ज नहीं"

        TidDiaryCalendarLoadEarlier ->
            "पहले के लोड करें"

        TidDiaryCalendarWeekdayFri ->
            "शु"

        TidDiaryCalendarWeekdayMon ->
            "सो"

        TidDiaryCalendarWeekdaySat ->
            "श"

        TidDiaryCalendarWeekdaySun ->
            "र"

        TidDiaryCalendarWeekdayThu ->
            "गु"

        TidDiaryCalendarWeekdayTue ->
            "मं"

        TidDiaryCalendarWeekdayWed ->
            "बु"

        TidDiaryCalories ->
            "कैलोरी"

        TidDiaryCarbs ->
            "कार्ब्स"

        TidDiaryDetails ->
            "विवरण"

        TidDiaryGoalMet ->
            "लक्ष्य पूरा हुआ"

        TidDiaryKcal hole0 ->
            hole0 ++ " kcal"

        TidDiaryKcalEaten ->
            "kcal खाया गया"

        TidDiaryKcalLeft hole0 ->
            hole0 ++ " kcal शेष"

        TidDiaryKcalOver hole0 ->
            hole0 ++ " kcal अधिक"

        TidDiaryLogLatestFrom hole0 ->
            hole0 ++ " से नवीनतम दर्ज करें"

        TidDiaryLogging ->
            "दर्ज किया जा रहा है..."

        TidDiaryMacroGrams hole0 ->
            hole0 ++ " g"

        TidDiaryMacroGramsWithTarget hole0 hole1 ->
            hole0 ++ " / " ++ hole1 ++ " g"

        TidDiaryMacroSummaryGrams hole0 hole1 hole2 ->
            "कार्ब्स " ++ hole0 ++ "g ⋅ प्रोटीन " ++ hole1 ++ "g ⋅ वसा " ++ hole2 ++ "g"

        TidDiaryMacroSummaryPercent hole0 hole1 hole2 ->
            "कार्ब्स " ++ hole0 ++ "% ⋅ प्रोटीन " ++ hole1 ++ "% ⋅ वसा " ++ hole2 ++ "%"

        TidDiaryNextDay ->
            "अगला दिन"

        TidDiaryNoItems ->
            "कोई आइटम नहीं"

        TidDiaryOfKcal hole0 ->
            hole0 ++ " kcal में से"

        TidDiaryOther ->
            "अन्य"

        TidDiaryPreviousDay ->
            "पिछला दिन"

        TidDiarySettingsMealSlotsDescription ->
            "अपनी डायरी में दिखने वाले निश्चित भोजन स्लॉट चुनें।"

        TidDiarySettingsMealSlotsTitle ->
            "भोजन स्लॉट"

        TidDiarySettingsSave ->
            "भोजन स्लॉट सहेजें"

        TidDiarySettingsSaved ->
            "सहेजा गया"

        TidDiarySettingsSelectAtLeastOne ->
            "कम से कम एक भोजन स्लॉट चुनें।"

        TidFoodEditorAddCategory ->
            "श्रेणी जोड़ें"

        TidFoodEditorAddNutrient ->
            "+ पोषक तत्व जोड़ें"

        TidFoodEditorAddRowHint ->
            "सहेजने के लिए कैलोरी और मैक्रो (प्रति 100g) दर्ज करें।"

        TidFoodEditorAddServing ->
            "+ सर्विंग जोड़ें"

        TidFoodEditorAmountForPortion ->
            "इस हिस्से के लिए मात्रा"

        TidFoodEditorAmountPer100g ->
            "प्रति 100 g मात्रा"

        TidFoodEditorBasicInfo ->
            "बुनियादी जानकारी"

        TidFoodEditorBrand ->
            "ब्रांड"

        TidFoodEditorCategories ->
            "श्रेणियाँ"

        TidFoodEditorCategoriesHint ->
            "इस खाद्य पदार्थ को टैग करने के लिए दर्ज करें (या जोड़ें पर क्लिक करें)।"

        TidFoodEditorDateLabel ->
            "दिनांक (YYYY-MM-DD)"

        TidFoodEditorDefaultPortion ->
            "डिफ़ॉल्ट हिस्सा"

        TidFoodEditorDefaultPortionHint100g ->
            "वैकल्पिक। भोजन दर्ज करना 100 g से शुरू होगा।"

        TidFoodEditorDefaultPortionHintCount ->
            "चुनी गई सर्विंग में से कितनी पहले से भरनी है, दर्ज करें।"

        TidFoodEditorDefaultPortionHintGrams ->
            "यह भोजन दर्ज करते समय पहले से भरने के लिए ग्राम मात्रा दर्ज करें।"

        TidFoodEditorDefaultPortionHintServing ->
            "वैकल्पिक। भोजन दर्ज करना पहली सर्विंग से शुरू होगा।"

        TidFoodEditorDefaultQuantity ->
            "डिफ़ॉल्ट मात्रा"

        TidFoodEditorDefaultUnit ->
            "डिफ़ॉल्ट इकाई"

        TidFoodEditorErrorDuplicateNutrient ->
            "प्रत्येक पोषक तत्व केवल एक बार जोड़ा जा सकता है।"

        TidFoodEditorErrorDuplicateServingUnit hole0 ->
            "प्रत्येक सर्विंग के लिए अनोखी इकाई होनी चाहिए (डुप्लिकेट: " ++ hole0 ++ ")"

        TidFoodEditorErrorFoodNameRequired ->
            "खाद्य पदार्थ का नाम आवश्यक है।"

        TidFoodEditorErrorGreaterThanZero hole0 ->
            hole0 ++ " शून्य से अधिक होना चाहिए।"

        TidFoodEditorErrorInvalidDate ->
            "YYYY-MM-DD प्रारूप में एक मान्य दिनांक दर्ज करें।"

        TidFoodEditorErrorInvalidDefaultPortion ->
            "डिफ़ॉल्ट हिस्सा ग्राम में होना चाहिए या कॉन्फ़िगर की गई सर्विंग इकाई का उपयोग करना चाहिए"

        TidFoodEditorErrorMissingCoreMacros ->
            "अनुमान में कैलोरी या कोई आवश्यक मैक्रोन्यूट्रिएंट गायब है।"

        TidFoodEditorErrorNameRequired ->
            "नाम आवश्यक है"

        TidFoodEditorErrorNotConfigured ->
            "यह संपादक भोजन दर्ज करने के लिए कॉन्फ़िगर नहीं है।"

        TidFoodEditorErrorNumberGreaterThanZero hole0 ->
            hole0 ++ " शून्य से अधिक संख्या होनी चाहिए।"

        TidFoodEditorErrorNutrientAmountNonNegative hole0 ->
            "पोषक तत्व की मात्रा एक गैर-ऋणात्मक संख्या होनी चाहिए (प्राप्त: " ++ hole0 ++ ")"

        TidFoodEditorErrorNutrientRequired hole0 ->
            hole0 ++ " आवश्यक है।"

        TidFoodEditorErrorPortionTooLarge ->
            "हिस्से के मान सुरक्षित रूप से गणना करने के लिए बहुत बड़े हैं।"

        TidFoodEditorErrorPortionWeightRequired ->
            "इस दर्ज किए गए हिस्से का वज़न आवश्यक है।"

        TidFoodEditorErrorRequiredNumber hole0 ->
            hole0 ++ " आवश्यक है और एक संख्या होनी चाहिए।"

        TidFoodEditorErrorSelectNutrient ->
            "हर दर्ज की गई मात्रा के लिए एक पोषक तत्व चुनें।"

        TidFoodEditorErrorServingGramsPositive hole0 ->
            "प्रति सर्विंग इकाई ग्राम एक धनात्मक संख्या होनी चाहिए (प्राप्त: " ++ hole0 ++ ")"

        TidFoodEditorErrorUnsupportedNutrient hole0 ->
            "अनुमान में एक असमर्थित पोषक तत्व है: " ++ hole0

        TidFoodEditorErrorZeroOrGreater hole0 ->
            hole0 ++ " शून्य या उससे अधिक होना चाहिए।"

        TidFoodEditorGrams ->
            "ग्राम"

        TidFoodEditorGramsPerUnit ->
            "प्रति इकाई ग्राम"

        TidFoodEditorLabelEstimatedNutrient ->
            "अनुमानित पोषक तत्व"

        TidFoodEditorLabelPortionWeight ->
            "इस दर्ज किए गए हिस्से का वज़न"

        TidFoodEditorLabelSuggestedPortionWeight ->
            "सुझाया गया हिस्सा वज़न"

        TidFoodEditorLogDetails ->
            "लॉग विवरण"

        TidFoodEditorLoggedPortion ->
            "दर्ज किया गया हिस्सा"

        TidFoodEditorLoggedPortionHint ->
            "आप जो पूरी मात्रा दर्ज कर रहे हैं उसका वर्णन करें।"

        TidFoodEditorMealNone ->
            "कोई नहीं"

        TidFoodEditorName ->
            "नाम"

        TidFoodEditorNoCategories ->
            "अभी कोई श्रेणी नहीं"

        TidFoodEditorNoDefault ->
            "कोई डिफ़ॉल्ट नहीं"

        TidFoodEditorNotes ->
            "नोट्स (वैकल्पिक)"

        TidFoodEditorNutrientsTitle ->
            "पोषक तत्व"

        TidFoodEditorPortionHint ->
            "पूरे दर्ज किए गए हिस्से के कुल मान दर्ज करें। कैलोरी, प्रोटीन, कार्बोहाइड्रेट और वसा आवश्यक हैं।"

        TidFoodEditorPortionNutrition ->
            "हिस्से का पोषण"

        TidFoodEditorPortionUnit ->
            "हिस्से की इकाई"

        TidFoodEditorPortionWeightLabel ->
            "इस दर्ज किए गए हिस्से का वज़न (g)"

        TidFoodEditorRemove ->
            "हटाएँ"

        TidFoodEditorSaveToFoods ->
            "मेरे खाद्य पदार्थों में सहेजें"

        TidFoodEditorSaveToFoodsDescription ->
            "इसे दर्ज करने से पहले दोबारा उपयोग योग्य कस्टम खाद्य पदार्थ के रूप में सहेजें।"

        TidFoodEditorSelectNutrient ->
            "पोषक तत्व चुनें..."

        TidFoodEditorServings ->
            "सर्विंग"

        TidFoodEditorServingsEmpty ->
            "कप, टुकड़ों या अन्य इकाइयों में हिस्से परिभाषित करने के लिए एक सर्विंग जोड़ें।"

        TidFoodEditorUnitPlaceholder ->
            "इकाई"

        TidFoodEditorUses hole0 ->
            hole0 ++ " उपयोग"

        TidFoodLogAmountRequired ->
            "मात्रा आवश्यक है।"

        TidFoodLogDelete ->
            "लॉग हटाएँ"

        TidFoodLogDeleteConfirmDescription ->
            "यह लॉग प्रविष्टि स्थायी रूप से हटा दी जाएगी।"

        TidFoodLogDeleteConfirmTitle ->
            "लॉग हटाएँ?"

        TidFoodLogInvalidDeviceDate ->
            "डिवाइस की तारीख़ नहीं पढ़ी जा सकी।"

        TidFoodLogLogged hole0 ->
            "दर्ज किया गया " ++ hole0

        TidFoodLogNotes ->
            "नोट्स"

        TidFoodLogRetryLogging ->
            "दर्ज करना दोबारा प्रयास करें"

        TidFoodLogSavedNotLogged ->
            "खाद्य पदार्थ मेरे खाद्य पदार्थों में सहेजा गया, लेकिन दर्ज नहीं किया जा सका।"

        TidFoodSearchAdHocDescription ->
            "किसी खाद्य पदार्थ को अपने खाद्य पदार्थों में सहेजे बिना एक बार का भोजन दर्ज करें।"

        TidFoodSearchAdHocTitle ->
            "एक तदर्थ भोजन लॉग बनाएँ"

        TidFoodSearchAdding ->
            "जोड़ा जा रहा है..."

        TidFoodSearchBarcodeNotFound ->
            "उस बारकोड के लिए कोई खाद्य पदार्थ नहीं मिला।"

        TidFoodSearchCenterBarcode ->
            "बारकोड को गाइड पर केंद्रित करें।"

        TidFoodSearchEmptyPrompt ->
            "शुरू करने के लिए कोई खाद्य पदार्थ खोजें।"

        TidFoodSearchEnterBarcode ->
            "बारकोड दर्ज करें"

        TidFoodSearchEnterBarcodePrompt ->
            "खाद्य पदार्थ खोजने के लिए बारकोड दर्ज करें।"

        TidFoodSearchEnterManually ->
            "मैन्युअल रूप से दर्ज करें"

        TidFoodSearchErrorCouldNotReadDate ->
            "चुनी गई तारीख़ नहीं पढ़ी जा सकी।"

        TidFoodSearchErrorScannerStart ->
            "बारकोड स्कैनर शुरू नहीं हो सका।"

        TidFoodSearchNoCustomFoods ->
            "कोई कस्टम खाद्य पदार्थ नहीं मिला। कोई अलग खोज आज़माएँ।"

        TidFoodSearchNoFoods ->
            "कोई खाद्य पदार्थ नहीं मिला। कोई अलग खोज आज़माएँ।"

        TidFoodSearchNoLoggedFoods ->
            "कोई दर्ज किया गया खाद्य पदार्थ नहीं मिला। कोई अलग खोज आज़माएँ।"

        TidFoodSearchNoRecents ->
            "अभी कोई हालिया खाद्य पदार्थ नहीं। शुरू करने के लिए कोई खाद्य पदार्थ खोजें।"

        TidFoodSearchOpeningFood ->
            "खाद्य पदार्थ खोला जा रहा है।"

        TidFoodSearchPromptAll ->
            "कोई खाद्य पदार्थ खोजें"

        TidFoodSearchPromptCustom ->
            "अपने कस्टम खाद्य पदार्थ खोजें"

        TidFoodSearchPromptHistory ->
            "अपने दर्ज किए गए खाद्य पदार्थ खोजें"

        TidFoodSearchRecent ->
            "हालिया"

        TidFoodSearchResults ->
            "परिणाम"

        TidFoodSearchScan ->
            "स्कैन करें"

        TidFoodSearchScopeAll ->
            "सभी"

        TidFoodSearchScopeBarcode ->
            "बारकोड"

        TidFoodSearchScopeCustom ->
            "कस्टम"

        TidFoodSearchScopeHistory ->
            "इतिहास"

        TidFoodSearchSearching ->
            "खोज रहा है"

        TidFoodSearchStarting ->
            "शुरू हो रहा है"

        TidFoodSearchStartingCamera ->
            "कैमरा शुरू हो रहा है..."

        TidFoodShowLogging ->
            "दर्ज किया जा रहा है..."

        TidFoodShowPortion ->
            "हिस्सा"

        TidGoalSettingsCalories ->
            "कैलोरी"

        TidGoalSettingsCarbs ->
            "कार्ब्स (g)"

        TidGoalSettingsDailyTargetsTitle ->
            "दैनिक लक्ष्य"

        TidGoalSettingsErrorCaloriesMacros ->
            "कैलोरी प्रोटीन*4 + कार्ब्स*4 + वसा*9 के बराबर होनी चाहिए।"

        TidGoalSettingsErrorCaloriesPositive ->
            "कैलोरी 0 से अधिक होनी चाहिए।"

        TidGoalSettingsErrorInvalidNumbers ->
            "सभी लक्ष्य फ़ील्ड के लिए मान्य संख्याएँ दर्ज करें।"

        TidGoalSettingsErrorMacrosNonNegative ->
            "प्रोटीन, कार्ब्स और वसा 0 या उससे अधिक होने चाहिए।"

        TidGoalSettingsFat ->
            "वसा (g)"

        TidGoalSettingsProtein ->
            "प्रोटीन (g)"

        TidGoalSettingsSave ->
            "लक्ष्य सहेजें"

        TidGoalSettingsStatusDefaultAfter hole0 ->
            hole0 ++ " के बाद बैकएंड डिफ़ॉल्ट का उपयोग।"

        TidGoalSettingsStatusDefaultForDate ->
            "इस तारीख़ के लिए बैकएंड डिफ़ॉल्ट का उपयोग।"

        TidGoalSettingsStatusSavedActive ->
            "सहेजे गए लक्ष्य सक्रिय हैं।"

        TidGoalSettingsStatusSavedFrom hole0 ->
            "सहेजे गए लक्ष्य " ++ hole0 ++ " से प्रभावी।"

        TidLoginPasswordRequired ->
            "पासवर्ड आवश्यक है"

        TidLoginSubmit ->
            "लॉग इन करें"

        TidLoginSubmitting ->
            "लॉग इन किया जा रहा है..."

        TidLoginTitle ->
            "लॉग इन करें"

        TidMealAddComponent ->
            "+ घटक जोड़ें"

        TidMealComponentRequired ->
            "चुने गए उत्पाद वाला कम से कम एक घटक आवश्यक है"

        TidMealComponents ->
            "घटक"

        TidMealComponentsCount hole0 ->
            hole0 ++ " घटक"

        TidMealDelete ->
            "भोजन हटाएँ"

        TidMealDeleteConfirmDescription ->
            "यह भोजन स्थायी रूप से हटा दिया जाएगा।"

        TidMealDeleteConfirmTitle ->
            "भोजन हटाएँ?"

        TidMealListCreate ->
            "+ भोजन बनाएँ"

        TidMealNotes ->
            "नोट्स"

        TidMealQty ->
            "मात्रा"

        TidMealSearchProduct ->
            "उत्पाद खोजें"

        TidMealSearchingFoods ->
            "खाद्य पदार्थ खोजे जा रहे हैं..."

        TidMealSlotBreakfast ->
            "नाश्ता"

        TidMealSlotDinner ->
            "रात का भोजन"

        TidMealSlotLateNightSnack ->
            "देर रात का अल्पाहार"

        TidMealSlotLunch ->
            "दोपहर का भोजन"

        TidMealSlotSnack ->
            "अल्पाहार"

        TidMealTotal ->
            "कुल"

        TidMealTotalQuantity ->
            "कुल मात्रा"

        TidMealTotalUnit ->
            "कुल इकाई"

        TidMealUnknownFood ->
            "अज्ञात भोजन"

        TidMealUpdate ->
            "भोजन अपडेट करें"

        TidNavAdmin ->
            "एडमिन"

        TidNavApiKeys ->
            "API कुंजियाँ"

        TidNavBack ->
            "वापस"

        TidNavCalendar ->
            "कैलेंडर"

        TidNavDiary ->
            "डायरी"

        TidNavFoods ->
            "खाद्य पदार्थ"

        TidNavGoals ->
            "लक्ष्य"

        TidNavLogout ->
            "लॉग आउट"

        TidNavMealSlots ->
            "भोजन स्लॉट"

        TidNavMeals ->
            "भोजन"

        TidNavMenu ->
            "मेनू"

        TidNavMyFoods ->
            "मेरे खाद्य पदार्थ"

        TidNavMyMeals ->
            "मेरे भोजन"

        TidNavSearch ->
            "खोजें"

        TidNavSearchFoods ->
            "खाद्य पदार्थ खोजें"

        TidNutrientAddedSugars ->
            "अतिरिक्त शर्करा"

        TidNutrientCalcium ->
            "कैल्शियम"

        TidNutrientCarbRich ->
            "कार्ब युक्त"

        TidNutrientCarbohydrates ->
            "कार्बोहाइड्रेट"

        TidNutrientCholesterol ->
            "कोलेस्ट्रॉल"

        TidNutrientEnergy ->
            "ऊर्जा"

        TidNutrientFat ->
            "वसा"

        TidNutrientFatRich ->
            "वसा युक्त"

        TidNutrientFiber ->
            "फ़ाइबर"

        TidNutrientFolate ->
            "फ़ोलेट"

        TidNutrientIron ->
            "लोहा"

        TidNutrientLegendCarbs hole0 ->
            "कार्ब्स " ++ hole0 ++ "g"

        TidNutrientLegendFat hole0 ->
            "वसा " ++ hole0 ++ "g"

        TidNutrientLegendProtein hole0 ->
            "प्रोटीन " ++ hole0 ++ "g"

        TidNutrientMagnesium ->
            "मैग्नीशियम"

        TidNutrientMonounsaturatedFat ->
            "मोनोअनसैचुरेटेड वसा"

        TidNutrientNutrition ->
            "पोषण"

        TidNutrientPhosphorus ->
            "फ़ॉस्फ़ोरस"

        TidNutrientPolyunsaturatedFat ->
            "पॉलीअनसैचुरेटेड वसा"

        TidNutrientPotassium ->
            "पोटैशियम"

        TidNutrientProtein ->
            "प्रोटीन"

        TidNutrientProteinRich ->
            "प्रोटीन युक्त"

        TidNutrientSaturatedFat ->
            "संतृप्त वसा"

        TidNutrientSodium ->
            "सोडियम"

        TidNutrientStarch ->
            "स्टार्च"

        TidNutrientSugar ->
            "शर्करा"

        TidNutrientTableAmount ->
            "मात्रा"

        TidNutrientTableNutrient ->
            "पोषक तत्व"

        TidNutrientTableUnit ->
            "इकाई"

        TidNutrientTransFat ->
            "ट्रांस वसा"

        TidNutrientUnavailable ->
            "अनुपलब्ध"

        TidNutrientVitaminA ->
            "विटामिन A"

        TidNutrientVitaminB12 ->
            "विटामिन B12"

        TidNutrientVitaminB6 ->
            "विटामिन B6"

        TidNutrientVitaminC ->
            "विटामिन C"

        TidNutrientVitaminD ->
            "विटामिन D"

        TidNutrientVitaminE ->
            "विटामिन E"

        TidNutrientZinc ->
            "ज़िंक"

        TidNutritionDetailsAboutReferences ->
            "इन संदर्भों के बारे में"

        TidNutritionDetailsAdviceAddedSugar ->
            "अतिरिक्त शर्करा की दैनिक सीमा होती है, लक्ष्य नहीं।"

        TidNutritionDetailsAdviceCalcium ->
            "कैल्शियम के कुल मान आपके दर्ज किए गए आइटम दर्शाते हैं।"

        TidNutritionDetailsAdviceCholesterol ->
            "आहार कोलेस्ट्रॉल रक्त कोलेस्ट्रॉल पर केवल एक प्रभाव है; संतृप्त और ट्रांस वसा अक्सर अधिक कारगर होते हैं।"

        TidNutritionDetailsAdviceDefault ->
            "यह इस दिन दर्ज किए गए आइटम दर्शाता है।"

        TidNutritionDetailsAdviceFiber ->
            "फ़ाइबर पाचन स्वास्थ्य में सहायता करता है। संदर्भ से एक दिन कम होना कमी नहीं दर्शाता।"

        TidNutritionDetailsAdviceIron ->
            "लोहे की आवश्यकता जीवन-चरण के अनुसार बदलती है; यह एक सामान्य संदर्भ है।"

        TidNutritionDetailsAdviceMagnesium ->
            "FDA दैनिक मान 420 mg है। वयस्कों के लिए, National Academies की 350 mg ऊपरी सीमा केवल पूरक और दवाओं से मिलने वाले मैग्नीशियम पर लागू होती है, भोजन पर नहीं।"

        TidNutritionDetailsAdvicePotassium ->
            "पोटैशियम FDA दैनिक संदर्भ के अनुसार दिखाया गया है।"

        TidNutritionDetailsAdviceSaturatedFat ->
            "यह एक दैनिक सीमा है। कुछ संतृप्त वसा को असंतृप्त वसा से बदलना आम तौर पर वसा को पूरी तरह हटाने से अधिक उपयोगी होता है।"

        TidNutritionDetailsAdviceSodium ->
            "सोडियम एक दैनिक सीमा है, पीछा करने का लक्ष्य नहीं।"

        TidNutritionDetailsAdviceSugar ->
            "इसमें प्राकृतिक और अतिरिक्त शर्करा शामिल हैं; FDA कुल शर्करा के लिए कोई दैनिक मान निर्धारित नहीं करता।"

        TidNutritionDetailsAdviceTransFat ->
            "कोई FDA दैनिक मान नहीं; सेवन यथासंभव कम रखें।"

        TidNutritionDetailsAdviceUnsaturatedFats ->
            "असंतृप्त वसा वसा की गुणवत्ता का संदर्भ देते हैं; कोई एकल FDA दैनिक लक्ष्य नहीं है।"

        TidNutritionDetailsAdviceVitaminB12 ->
            "दैनिक संदर्भ से अधिक को चेतावनी के रूप में नहीं दिखाया जाता।"

        TidNutritionDetailsAdviceVitaminD ->
            "दर्ज किए गए आइटम में विटामिन D आपके कुल सेवन का केवल एक हिस्सा है।"

        TidNutritionDetailsDailyReferenceReached ->
            "दैनिक संदर्भ प्राप्त"

        TidNutritionDetailsFats ->
            "वसा"

        TidNutritionDetailsKnownMinimum ->
            "ज्ञात न्यूनतम"

        TidNutritionDetailsKnownMinimumAmount hole0 ->
            hole0 ++ " एक ज्ञात न्यूनतम है"

        TidNutritionDetailsLoggedItemsIncludedOne hole0 ->
            hole0 ++ " दर्ज किया गया आइटम इन दैनिक कुल में शामिल है।"

        TidNutritionDetailsLoggedItemsIncludedOther hole0 ->
            hole0 ++ " दर्ज किए गए आइटम इन दैनिक कुल में शामिल हैं।"

        TidNutritionDetailsMissingNutrientNotice ->
            "कुछ दर्ज किए गए आइटम हर पोषक तत्व नहीं बताते, इसलिए वे कुल उपलब्ध नहीं हैं।"

        TidNutritionDetailsNextDay ->
            "अगला दिन"

        TidNutritionDetailsNoDailyReference ->
            "कोई दैनिक संदर्भ नहीं"

        TidNutritionDetailsNoData ->
            "कोई डेटा नहीं"

        TidNutritionDetailsNoItemsLogged ->
            "इस दिन कोई आइटम दर्ज नहीं किया गया, इसलिए पोषण विवरण उपलब्ध नहीं है।"

        TidNutritionDetailsNoKnownAmount ->
            "कोई ज्ञात मात्रा नहीं"

        TidNutritionDetailsNoNutrientData ->
            "इस समूह के लिए कोई पोषक तत्व डेटा उपलब्ध नहीं है।"

        TidNutritionDetailsNutrientsToLimit ->
            "सीमित करने योग्य पोषक तत्व"

        TidNutritionDetailsOverDailyLimit hole0 ->
            hole0 ++ " दैनिक सीमा से अधिक"

        TidNutritionDetailsOverview ->
            "अवलोकन"

        TidNutritionDetailsOverviewEmpty ->
            "कोई अवलोकन डेटा उपलब्ध नहीं है।"

        TidNutritionDetailsPartialCoverageNotice ->
            "कुछ दर्ज किए गए आइटम में अपूर्ण पोषण डेटा है। आंशिक मात्राएँ ज्ञात न्यूनतम हैं।"

        TidNutritionDetailsPartialData ->
            "आंशिक डेटा"

        TidNutritionDetailsPreviousDay ->
            "पिछला दिन"

        TidNutritionDetailsReferencesDescription hole0 hole1 hole2 hole3 ->
            "ये तुलनाएँ " ++ hole3 ++ " के लिए " ++ hole1 ++ " (" ++ hole2 ++ ") से " ++ hole0 ++ " का उपयोग करती हैं। ये सूचनात्मक दैनिक तुलनाएँ हैं, चिकित्सा निदान नहीं।"

        TidNutritionDetailsRemaining hole0 ->
            hole0 ++ " शेष"

        TidNutritionDetailsToDailyReference hole0 ->
            "दैनिक संदर्भ तक " ++ hole0

        TidNutritionDetailsUnknownOfAmount hole0 ->
            "— " ++ hole0 ++ " में से"

        TidNutritionDetailsViewReferenceSource ->
            "संदर्भ स्रोत देखें"

        TidNutritionDetailsVitaminsMinerals ->
            "विटामिन और खनिज"

        TidSearchKcalPer100g hole0 ->
            hole0 ++ " kcal प्रति 100 g"

        TidSetupDescription ->
            "शुरू करने के लिए एडमिन खाता बनाएँ।"

        TidSetupPasswordMinLength ->
            "पासवर्ड कम से कम 8 वर्णों का होना चाहिए"

        TidSetupSubmit ->
            "एडमिन बनाएँ"

        TidSetupSubmitting ->
            "बनाया जा रहा है..."

        TidSetupTitle ->
            "पहली बार सेटअप"

        TidTitleAddToMealSlot hole0 ->
            hole0 ++ " में जोड़ें"

        TidTitleAdmin ->
            "एडमिन"

        TidTitleApiKeys ->
            "API कुंजियाँ"

        TidTitleCalendar ->
            "कैलेंडर"

        TidTitleCreateFood ->
            "खाद्य पदार्थ बनाएँ"

        TidTitleCreateMeal ->
            "भोजन बनाएँ"

        TidTitleCreateUser ->
            "उपयोगकर्ता बनाएँ"

        TidTitleCreateWithAi ->
            "AI के साथ बनाएँ"

        TidTitleDiary ->
            "डायरी"

        TidTitleDiarySettings ->
            "डायरी सेटिंग्स"

        TidTitleEditFood ->
            "खाद्य पदार्थ संपादित करें"

        TidTitleEditLog ->
            "लॉग संपादित करें"

        TidTitleEditMeal ->
            "भोजन संपादित करें"

        TidTitleEditUser ->
            "उपयोगकर्ता संपादित करें"

        TidTitleFood ->
            "खाद्य पदार्थ"

        TidTitleGoals ->
            "लक्ष्य"

        TidTitleLogFood ->
            "भोजन दर्ज करें"

        TidTitleLogWithAi ->
            "AI के साथ दर्ज करें"

        TidTitleLogin ->
            "लॉग इन"

        TidTitleManualFoodLog ->
            "मैन्युअल भोजन लॉग"

        TidTitleMeal ->
            "भोजन"

        TidTitleMyFoods ->
            "मेरे खाद्य पदार्थ"

        TidTitleMyMeals ->
            "मेरे भोजन"

        TidTitleNutritionDetails ->
            "पोषण विवरण"

        TidTitleSearchFoods ->
            "खाद्य पदार्थ खोजें"

        TidTitleSetup ->
            "सेटअप"

        TidUiCategoryOverflowMore hole0 ->
            "+" ++ hole0 ++ " और"

        TidUiDetailRowLabelSuffix hole0 ->
            hole0 ++ ":"

        TidUiRemoveNamed hole0 ->
            hole0 ++ " हटाएँ"

        TidUiRetry ->
            "दोबारा प्रयास करें"

        TidUiSelectPlaceholder ->
            "चुनें…"

        TidUiUnitWithCode hole0 hole1 ->
            hole0 ++ " (" ++ hole1 ++ ")"

        TidUsersCreateUser ->
            "+ उपयोगकर्ता बनाएँ"

        TidUsersCredentials ->
            "क्रेडेंशियल"

        TidUsersDisableConfirmDescription ->
            "यह उपयोगकर्ता अब साइन इन नहीं कर पाएगा।"

        TidUsersDisableConfirmTitle ->
            "उपयोगकर्ता अक्षम करें?"

        TidUsersDisableUser ->
            "उपयोगकर्ता अक्षम करें"

        TidUsersDisabling ->
            "अक्षम किया जा रहा है..."

        TidUsersDisplayNameRequired ->
            "प्रदर्शित नाम आवश्यक है"

        TidUsersEnableUser ->
            "उपयोगकर्ता सक्षम करें"

        TidUsersEnabling ->
            "सक्षम किया जा रहा है..."

        TidUsersInitialPassword ->
            "प्रारंभिक पासवर्ड"

        TidUsersInitialPasswordRequired ->
            "प्रारंभिक पासवर्ड आवश्यक है"

        TidUsersLoadFailed hole0 ->
            "उपयोगकर्ता लोड नहीं हो सका: " ++ hole0

        TidUsersNewPassword ->
            "नया पासवर्ड"

        TidUsersNewPasswordRequired ->
            "नया पासवर्ड आवश्यक है"

        TidUsersResetPassword ->
            "पासवर्ड रीसेट करें"

        TidUsersResetting ->
            "रीसेट किया जा रहा है..."

        TidUsersSectionTitle ->
            "उपयोगकर्ता"
