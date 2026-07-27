import 'package:flutter/material.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/models/property_model.dart';
import 'edit_property_screen.dart';

/// Loads a property by id, then shows [EditPropertyScreen]. Mirrors
/// PropertyDetailLoaderScreen.
///
/// The edit screen must never be handed a [PropertyModel] captured by whatever
/// screen pushed it: it renders that snapshot AND uses it as the baseline for
/// "did the ownership doc change?", so a stale one both shows the wrong doc type
/// and mis-decides whether the change needs re-review. Loading by id makes the
/// baseline the stored state, which is the only thing the rules agree with.
class EditPropertyLoaderScreen extends StatelessWidget {
  final String propertyId;

  const EditPropertyLoaderScreen({super.key, required this.propertyId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PropertyModel?>(
      future: PropertyService().getProperty(propertyId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final property = snapshot.data;
        if (property == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'This property could not be found.',
                  style: AppTextStyles.bodyMedium
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        return EditPropertyScreen(property: property);
      },
    );
  }
}
