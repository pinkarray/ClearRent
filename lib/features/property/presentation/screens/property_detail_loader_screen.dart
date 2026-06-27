import 'package:flutter/material.dart';
import '../../../../core/constants/colors.dart';
import '../../../../core/constants/text_styles.dart';
import '../../../../services/property_service.dart';
import '../../../../shared/models/property_model.dart';
import 'property_detail_screen.dart';

/// Loads a property by id, then shows [PropertyDetailScreen]. Used by deep
/// links (e.g. a rent-change notification) that only carry the propertyId,
/// not the full [PropertyModel].
class PropertyDetailLoaderScreen extends StatelessWidget {
  final String propertyId;

  const PropertyDetailLoaderScreen({super.key, required this.propertyId});

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
        return PropertyDetailScreen(property: property);
      },
    );
  }
}
